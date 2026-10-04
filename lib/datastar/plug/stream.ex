if Code.ensure_loaded?(Plug) do
  defmodule Datastar.Plug.Stream do
    @moduledoc """
    A read-side SSE stream loop over `%Plug.Conn{}`.

    `run/3` owns the order of operations every Datastar read stream needs —
    subscribe, start the response, take a snapshot, then receive and patch —
    and builds entirely on `Datastar.Plug`'s primitives without changing any
    of them.

    The loop runs **in the request process** and spawns nothing, so the
    single-writer contract (SDK core spec §10.4) holds by construction.

    ## Handlers return events, not connections

    `:handle` and `:on_start` return a `t:decision/0`, never a
    `%Plug.Conn{}`. That is what makes them ordinary functions: a handler is
    tested by calling it, with no socket and no connection in sight.

    ## A list stream

        get "/stream" do
          Datastar.Plug.Stream.run(conn, :no_state,
            subscribe: fn -> PubSub.subscribe(:items) end,
            on_start: &snapshot/1,
            handle: &handle/2
          )
        end

        defp snapshot(state),
          do: {:patch, Datastar.patch_elements(Render.index_main(Store.list())), state}

        defp handle({:items_changed}, state), do: snapshot(state)
        defp handle(_other, state), do: {:noreply, state}

    ## A detail stream that may already be gone

    `:on_start` returns the same decision as `:handle`, so the snapshot can
    end the stream. That matters when the thing being watched was deleted
    *before* this stream subscribed: no broadcast is coming, so the snapshot
    itself has to stop.

        get "/items/:id/stream" do
          with {:ok, item_id} <- parse_id(id),
               {:ok, _item} <- Store.fetch(item_id) do
            Datastar.Plug.Stream.run(conn, %{id: item_id},
              subscribe: fn -> PubSub.subscribe({:item, item_id}) end,
              on_start: &snapshot/1,
              handle: &handle/2
            )
          else
            _not_found -> send_resp(conn, 404, "Not found")
          end
        end

        defp snapshot(state) do
          case Store.fetch(state.id) do
            {:ok, item} -> {:patch, Datastar.patch_elements(Render.detail_main(item)), state}
            :error -> {:halt, Datastar.redirect("/"), state}
          end
        end

        defp handle({:item_changed}, state), do: snapshot(state)
        defp handle({:item_deleted}, state), do: {:halt, Datastar.redirect("/"), state}
        defp handle(_other, state), do: {:noreply, state}

    Note where the `404` lives: in the router, **before** `run/3`. Once the
    response starts, a missing record can no longer produce a status.

    ## Infrastructure messages

    Starting a chunked response posts `{:plug_conn, :sent}` to the request
    process — its own mailbox — so the first `receive` in a hand-written
    stream loop picks it up. `Plug.Conn`, Bandit and the Plug test adapter
    all do this. This loop swallows it, so `:handle` never sees it and a
    handler that pattern-matches its own messages strictly is safe.

    The loop cannot tell that message apart from an identical one sent by an
    application, so an application that sends `{:plug_conn, :sent}` itself
    will find it swallowed too. Nothing else is filtered: `:DOWN`, `:EXIT`
    and every other message reaches `:handle`, which is why a handler wants
    a catch-all clause.

    ## Heartbeats

    `:heartbeat` reserves **no message name** — there is no scheduled
    message to collide with anything an application sends — and its deadline
    is driven by **writes, not receives**. A stream that keeps receiving
    messages whose handler returns `{:noreply, state}` writes nothing, so it
    keeps emitting keep-alives; only an actual write defers the next one.

    That distinction matters because both jobs of a heartbeat depend on bytes
    reaching the client: keeping a buffering proxy from closing the
    connection, and noticing a disconnect, which only a failed write reveals.
    A timer reset by arriving messages would be held off indefinitely by
    traffic that produces no events — including the catch-all clause this
    module recommends.

    It defaults to `30_000`. An idle stream behind a buffering proxy dies
    without periodic bytes, and that failure is invisible in development;
    SSE comments are inert, so a default costs nothing.

    `:infinity` disables keep-alives **and disconnect detection with them**.
    A failed write is the only disconnect signal a stream gets, so a stream
    that never writes never learns the client is gone: it blocks in
    `receive` indefinitely, holding its subscription and its connection.
    Disable the heartbeat only when messages are certain to arrive, and to
    produce writes, regularly.

    ## When a handler raises

    The loop does not recover. It logs which message was being handled —
    bounded, so a large or sensitive payload is not dumped whole — and
    re-raises with the original stacktrace. The request process dies, the
    connection drops, the client reconnects, and `:subscribe` plus
    `:on_start` rebuild correct state.

    The response headers went out before the first message was handled, so
    **nothing the server does afterwards can produce an error status the
    user sees**. That is why the loop logs rather than rescues.

    The client bounds the retries itself: Datastar v1.0.4 retries with
    exponential backoff from one second, doubling, capped at thirty, and
    **gives up after ten attempts**, dispatching a `datastar-fetch`
    `retries-failed` event. Listening for that event is the quickest way to
    notice a broken stream from the browser.

    Two habits make this rare. Do everything that can fail **before**
    `run/3` — fetch the record, parse the id, authorize, validate — because
    afterwards a failure can only drop the stream, never return a `404`.
    And give `:handle` a catch-all clause, the way a `GenServer` is given a
    catch-all `handle_info/2`: `:DOWN`, `:EXIT` and monitor traffic all
    arrive here.

    For a gentler reconnect, set `:retry_duration` on an event — every
    constructor accepts it, and the client honours the SSE `retry` field,
    overriding its own interval:

        Datastar.patch_elements(html, retry_duration: 5_000)

    ## Examples

        iex> send(self(), :stop)
        iex> handle = fn :stop, state -> {:halt, state} end
        iex> Plug.Test.conn(:get, "/")
        ...> |> Datastar.Plug.Stream.run(:state, handle: handle)
        ...> |> Map.fetch!(:state)
        :chunked

    This module compiles only when the optional `:plug` dependency is
    present.
    """

    require Logger

    alias Datastar.Options

    @default_heartbeat 30_000
    @allowed_opts [:on_start, :subscribe, :handle, heartbeat: @default_heartbeat]

    @typedoc "Caller-owned loop state, threaded through every decision."
    @type state :: term()

    @typedoc "One event, or several written as a single chunk."
    @type event_or_events :: Datastar.SSE.event() | [Datastar.SSE.event()]

    @typedoc "What a handler returns."
    @type decision ::
            {:patch, event_or_events(), state()}
            | {:noreply, state()}
            | {:halt, state()}
            | {:halt, event_or_events(), state()}

    @type option ::
            {:handle, (term(), state() -> decision())}
            | {:on_start, (state() -> decision())}
            | {:subscribe, (-> any())}
            | {:heartbeat, pos_integer() | :infinity}

    @doc """
    Runs a Datastar read stream and returns the connection when it ends.

    Options:

      * `:handle` (required) — `(message, state)` returning a
        `t:decision/0`. Called for every message the loop receives.
      * `:on_start` — `(state)` returning a `t:decision/0`, applied once
        after the response starts. A `{:halt, …}` here ends the stream
        without entering the loop.
      * `:subscribe` — a zero-arity function run **before** anything else,
        so a change arriving between subscription and snapshot cannot be
        lost. Its return value is ignored.
      * `:heartbeat` — milliseconds between keep-alive comments, or
        `:infinity` to disable. Defaults to `30_000`.

    Set any response headers on the connection *before* calling this
    function; `run/3` calls `Datastar.Plug.start/2` itself.
    """
    @spec run(Plug.Conn.t(), state(), [option()]) :: Plug.Conn.t()
    def run(conn, state, opts) do
      opts = validate!(opts)

      run_subscribe(Keyword.get(opts, :subscribe))

      conn = Datastar.Plug.start(conn)

      case Keyword.fetch(opts, :on_start) do
        :error ->
          loop(conn, state, opts)

        {:ok, on_start} ->
          on_start
          |> call_on_start(state)
          |> apply_decision(conn, opts, fresh_deadline(opts))
      end
    end

    defp validate!(opts) do
      opts = Options.validate!(opts, @allowed_opts)

      validate_fun!(opts, :handle, 2, required: true)
      validate_fun!(opts, :on_start, 1, required: false)
      validate_fun!(opts, :subscribe, 0, required: false)
      validate_heartbeat!(opts)

      opts
    end

    defp validate_fun!(opts, key, arity, required: required?) do
      case Keyword.fetch(opts, key) do
        {:ok, fun} when is_function(fun, arity) ->
          :ok

        :error when not required? ->
          :ok

        other ->
          raise ArgumentError,
                "#{inspect(key)} must be a #{arity}-arity function, got: " <>
                  inspect(unwrap(other), limit: 5)
      end
    end

    defp unwrap({:ok, value}), do: value
    defp unwrap(:error), do: nil

    defp validate_heartbeat!(opts) do
      case Keyword.fetch!(opts, :heartbeat) do
        :infinity ->
          :ok

        milliseconds when is_integer(milliseconds) and milliseconds > 0 ->
          :ok

        other ->
          raise ArgumentError,
                ":heartbeat must be a positive integer or :infinity, got: " <>
                  inspect(other, limit: 5)
      end
    end

    defp run_subscribe(nil), do: :ok

    defp run_subscribe(subscribe) do
      subscribe.()
      :ok
    end

    defp loop(conn, state, opts), do: loop(conn, state, opts, fresh_deadline(opts))

    defp loop(conn, state, opts, deadline) do
      # The deadline is checked before receiving, not only expressed as the
      # `after` timeout. A `receive` always prefers an available message over
      # its `after` clause whatever the timeout - even `after 0` - so a
      # mailbox that is never empty would hold the keep-alive off forever.
      if remaining(deadline) == 0 do
        keep_alive(conn, state, opts)
      else
        case next_message(deadline) do
          :timeout ->
            keep_alive(conn, state, opts)

          {:message, message} ->
            opts
            |> Keyword.fetch!(:handle)
            |> call_handle(message, state)
            |> apply_decision(conn, opts, deadline)
        end
      end
    end

    defp keep_alive(conn, state, opts) do
      case Datastar.Plug.send_comment(conn, "keep-alive") do
        {:ok, conn} -> loop(conn, state, opts, fresh_deadline(opts))
        {:error, _reason} -> conn
      end
    end

    # The deadline is driven by WRITES, not receives. Both purposes of a
    # heartbeat - keeping a buffering proxy from closing an idle connection,
    # and noticing a disconnect, which only a failed write reveals - depend
    # on bytes reaching the client. A receive-reset timer would be held off
    # indefinitely by traffic whose handler returns {:noreply, state}, which
    # writes nothing, and that is the catch-all clause this module tells
    # authors to write.
    defp fresh_deadline(opts) do
      case Keyword.fetch!(opts, :heartbeat) do
        :infinity -> :infinity
        milliseconds -> System.monotonic_time(:millisecond) + milliseconds
      end
    end

    defp remaining(:infinity), do: :infinity
    defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

    # A stacktrace says where the handler broke, not which message broke it.
    # reraise/2 keeps the original stacktrace, so the framework's own report
    # is unchanged - this adds information and removes none.
    defp call_handle(handle, message, state) do
      handle.(message, state)
    rescue
      exception ->
        Logger.error(
          "Datastar stream handler raised while handling " <>
            inspect(message, limit: 5, printable_limit: 50)
        )

        reraise exception, __STACKTRACE__
    end

    defp call_on_start(on_start, state) do
      on_start.(state)
    rescue
      exception ->
        Logger.error("Datastar stream on_start raised while taking the initial snapshot")

        reraise exception, __STACKTRACE__
    end

    # Every real message is wrapped, so no application message can be
    # mistaken for the heartbeat timeout however it is named.
    defp next_message(deadline) do
      receive do
        {:plug_conn, :sent} -> next_message(deadline)
        message -> {:message, message}
      after
        remaining(deadline) -> :timeout
      end
    end

    # An ignored message leaves the deadline alone: nothing was written.
    defp apply_decision({:noreply, state}, conn, opts, deadline),
      do: loop(conn, state, opts, deadline)

    defp apply_decision({:patch, events, state}, conn, opts, deadline) do
      case events!(events) do
        # An empty patch writes nothing, so it cannot reset the deadline
        # either.
        [] ->
          loop(conn, state, opts, deadline)

        events ->
          case Datastar.Plug.send_events(conn, events) do
            {:ok, conn} -> loop(conn, state, opts, fresh_deadline(opts))
            {:error, _reason} -> conn
          end
      end
    end

    defp apply_decision({:halt, _state}, conn, _opts, _deadline), do: conn

    defp apply_decision({:halt, events, _state}, conn, _opts, _deadline) do
      case write(conn, events) do
        {:ok, conn} -> conn
        {:error, _reason} -> conn
      end
    end

    defp apply_decision(other, _conn, _opts, _deadline) do
      raise ArgumentError,
            "a stream handler must return {:patch, events, state}, {:noreply, state}, " <>
              "{:halt, state} or {:halt, events, state}, got: " <> inspect(other, limit: 5)
    end

    # `nil` is outside event_or_events/0 and its likely cause is a render
    # function that returned nothing. Letting List.wrap/1 turn it into an
    # empty write would make that bug a stream that stops updating with no
    # error, so it raises; `{:noreply, state}` is how a deliberate no-op is
    # expressed.
    defp events!(events) when is_non_struct_map(events), do: [events]
    defp events!(events) when is_list(events), do: events

    defp events!(other) do
      raise ArgumentError,
            "a decision's events must be an event map or a list of them, got: " <>
              inspect(other, limit: 5)
    end

    defp write(conn, events), do: Datastar.Plug.send_events(conn, events!(events))
  end
end
