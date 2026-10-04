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
          on_start.(state) |> apply_decision(conn, opts)
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

    defp loop(conn, state, opts) do
      case next_message(Keyword.fetch!(opts, :heartbeat)) do
        # Replaced by the keep-alive write in the next task.
        :timeout ->
          loop(conn, state, opts)

        {:message, message} ->
          handle = Keyword.fetch!(opts, :handle)

          handle.(message, state) |> apply_decision(conn, opts)
      end
    end

    # Every real message is wrapped, so no application message can be
    # mistaken for the heartbeat timeout however it is named.
    defp next_message(heartbeat) do
      receive do
        {:plug_conn, :sent} -> next_message(heartbeat)
        message -> {:message, message}
      after
        heartbeat -> :timeout
      end
    end

    defp apply_decision({:noreply, state}, conn, opts), do: loop(conn, state, opts)

    defp apply_decision({:patch, events, state}, conn, opts) do
      case write(conn, events) do
        {:ok, conn} -> loop(conn, state, opts)
        {:error, _reason} -> conn
      end
    end

    defp apply_decision({:halt, _state}, conn, _opts), do: conn

    defp apply_decision({:halt, events, _state}, conn, _opts) do
      case write(conn, events) do
        {:ok, conn} -> conn
        {:error, _reason} -> conn
      end
    end

    defp apply_decision(other, _conn, _opts) do
      raise ArgumentError,
            "a stream handler must return {:patch, events, state}, {:noreply, state}, " <>
              "{:halt, state} or {:halt, events, state}, got: " <> inspect(other, limit: 5)
    end

    defp write(conn, events), do: Datastar.Plug.send_events(conn, List.wrap(events))
  end
end
