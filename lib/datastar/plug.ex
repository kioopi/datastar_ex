if Code.ensure_loaded?(Plug) do
  defmodule Datastar.Plug.TransportError do
    @moduledoc """
    Raised by `Datastar.Plug.send_event!/2` when the transport rejects a
    chunk. Carries the adapter's original reason so callers can
    distinguish a closed connection from other failures.
    """

    defexception [:reason]

    @impl true
    def message(%__MODULE__{reason: reason}) do
      "Datastar SSE transport failed: #{inspect(reason)}"
    end
  end

  defmodule Datastar.Plug do
    @moduledoc """
    SSE transport over `%Plug.Conn{}` (SDK core spec §10).

    `start/2` initializes a chunked `text/event-stream` response;
    `send_event/2` encodes one semantic `Datastar.SSE.event()` with
    `Datastar.SSE.encode/1` and writes it as one chunk. This module never
    reinterprets Datastar datalines — construction stayed in the pure
    core.

    ## Single-writer contract

    A stream has one logical writer: the request process owns the
    `%Plug.Conn{}` and serializes all writes. Immutable conn structs do
    not make concurrent writes from processes holding copies safe —
    do not share a started conn across processes.

    ## Ordering

    Read incoming signals (`Datastar.Plug.Signals.read_signals/2`)
    *before* calling `start/2`: once the response is chunked, malformed
    input can no longer receive a plain 400.

    Compression middleware that buffers responses can delay event
    delivery; leave SSE responses uncompressed.

    This module compiles only when the optional `:plug` dependency is
    present.
    """

    alias Datastar.Options

    @doc """
    Starts a chunked SSE response.

    Sets `content-type: text/event-stream` and `cache-control: no-cache`
    exactly, deletes any `content-length`, adds `connection: keep-alive`
    only on HTTP/1.1, and calls `Plug.Conn.send_chunked/2` (status from
    `:status`, default 200) — which sends the response headers immediately.

    Raises `ArgumentError` if the response was already sent or on
    unknown options.

    ## A non-2xx status is not a way to deliver an error

    The Datastar client treats a non-2xx response as a failed request: on
    any status of 400 or above it dispatches a `datastar-fetch` error
    event carrying the status, rather than treating the response as an
    ordinary stream of patches. Delivering a validation error with `422`
    is therefore unreliable — it surfaces to the client's error handling
    rather than to the `$_error` signal it was written to.

    This function accepts `status: 422` without complaint, so the pattern
    has to be a convention rather than a check — *a rejection travels in a
    signal, not in the status line*:

        conn
        |> Datastar.Plug.start()
        |> Datastar.Plug.send_event!(Datastar.patch_signals(%{"_error" => message}))

    Answer `200` and let the client render the error from the signal.
    Reserve non-2xx for failures that happen *before* the stream starts —
    malformed signals, for instance, which is why signals are read first
    (§9.6).

    ## Other response headers

    Only `content-type`, `cache-control`, `connection` (HTTP/1.1 only) and
    `content-length` (which is deleted) are managed; nothing else is
    touched. Set anything else on the conn before calling this function:

        conn
        |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
        |> Datastar.Plug.start()

    `x-accel-buffering: no` is the one to remember: nginx buffers
    proxied responses by default, which delays every event until a
    buffer fills. For the same reason, leave SSE responses
    uncompressed — compression middleware that buffers can delay
    delivery indefinitely.

    ## Slow readers block the writer

    `Plug.Conn.chunk/2` blocks until the adapter accepts the bytes, so a
    client that reads slowly stalls whatever process is writing to it,
    and a long-lived stream will sit in a write rather than in its own
    receive loop.

    This **cannot be bounded from inside the request process**, which is
    why no `:write_timeout` option is offered: there is no way to
    abandon a `chunk/2` already in progress. Bounding a write requires
    writing from a separate process that can be killed, which this
    library does not provide. Plan for it in the application if slow
    clients matter.
    """
    @spec start(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def start(conn, opts \\ []) do
      opts = Options.validate!(opts, status: 200)
      ensure_not_sent!(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.delete_resp_header("content-length")
      |> maybe_keep_alive()
      |> Plug.Conn.send_chunked(Keyword.fetch!(opts, :status))
    end

    defp ensure_not_sent!(%Plug.Conn{state: state}) when state in [:unset, :set], do: :ok

    defp ensure_not_sent!(%Plug.Conn{state: state}) do
      raise ArgumentError,
            "cannot start an SSE response: response already sent (state: #{inspect(state)})"
    end

    defp maybe_keep_alive(conn) do
      if Plug.Conn.get_http_protocol(conn) == :"HTTP/1.1" do
        Plug.Conn.put_resp_header(conn, "connection", "keep-alive")
      else
        conn
      end
    end

    @doc """
    Encodes one semantic event with `Datastar.SSE.encode/1` and writes it
    as one chunk. Returns `{:error, reason}` on transport failure; raises
    `ArgumentError` before writing if the event itself is invalid. Never
    special-cases element, signal, or script events.
    """
    @spec send_event(Plug.Conn.t(), Datastar.SSE.event()) ::
            {:ok, Plug.Conn.t()} | {:error, term()}
    def send_event(conn, event) do
      encoded = Datastar.SSE.encode(event)
      Plug.Conn.chunk(conn, encoded)
    end

    @doc """
    Like `send_event/2`, but raises `Datastar.Plug.TransportError`
    (carrying the original reason) on transport failure.
    """
    @spec send_event!(Plug.Conn.t(), Datastar.SSE.event()) :: Plug.Conn.t()
    def send_event!(conn, event) do
      case send_event(conn, event) do
        {:ok, conn} -> conn
        {:error, reason} -> raise Datastar.Plug.TransportError, reason: reason
      end
    end

    @doc """
    Encodes every event and writes them as **one** chunk, in list order.

    Because `Datastar.SSE.encode/1` is pure, all encoding happens before
    anything is written: an invalid event raises `ArgumentError` with no
    bytes sent, so there is no partial-write state for a caller to
    recover from. An empty list writes nothing and returns `{:ok, conn}`.

    Returns `{:error, reason}` on transport failure, like `send_event/2`.
    The single-writer contract is unchanged — this is one write, not
    several.
    """
    @spec send_events(Plug.Conn.t(), [Datastar.SSE.event()]) ::
            {:ok, Plug.Conn.t()} | {:error, term()}
    def send_events(conn, []), do: {:ok, conn}

    def send_events(conn, events) when is_list(events) do
      Plug.Conn.chunk(conn, Enum.map(events, &Datastar.SSE.encode/1))
    end

    @doc """
    Like `send_events/2`, but raises `Datastar.Plug.TransportError`
    (carrying the original reason) on transport failure.
    """
    @spec send_events!(Plug.Conn.t(), [Datastar.SSE.event()]) :: Plug.Conn.t()
    def send_events!(conn, events) do
      case send_events(conn, events) do
        {:ok, conn} -> conn
        {:error, reason} -> raise Datastar.Plug.TransportError, reason: reason
      end
    end

    @doc """
    Writes comment lines (`Datastar.SSE.encode_comment/1`) as one chunk —
    a caller-driven heartbeat. Scheduling stays outside this module.
    """
    @spec send_comment(Plug.Conn.t(), String.t()) ::
            {:ok, Plug.Conn.t()} | {:error, term()}
    def send_comment(conn, comment) do
      Plug.Conn.chunk(conn, Datastar.SSE.encode_comment(comment))
    end

    @doc """
    Like `send_comment/2`, but raises `Datastar.Plug.TransportError`
    (carrying the original reason) on transport failure.

    The tuple-returning and raising forms exist for comments as well as
    events, so a command path that sends a heartbeat comment does not
    have to unwrap a result it has no use for.
    """
    @spec send_comment!(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
    def send_comment!(conn, comment) do
      case send_comment(conn, comment) do
        {:ok, conn} -> conn
        {:error, reason} -> raise Datastar.Plug.TransportError, reason: reason
      end
    end
  end
end
