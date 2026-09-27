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
    exactly, adds `connection: keep-alive` only on HTTP/1.1, and calls
    `Plug.Conn.send_chunked/2` (status from `:status`, default 200) —
    which sends the response headers immediately.

    Raises `ArgumentError` if the response was already sent or on
    unknown options.
    """
    @spec start(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def start(conn, opts \\ []) do
      Options.validate_keys!(opts, [:status])
      ensure_not_sent!(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> maybe_keep_alive()
      |> Plug.Conn.send_chunked(Keyword.get(opts, :status, 200))
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
  end
end
