if Code.ensure_loaded?(Plug) do
  defmodule Datastar.Plug.Test.ClosedAdapter do
    @moduledoc """
    A `Plug.Test` adapter shim that accepts `send_chunked/3` and fails
    every subsequent `chunk/2` with `{:error, :closed}`.

    Public only because `Datastar.Plug.Test.closed_conn/1` has to name it
    in a conn's `:adapter` field; call that function instead of using
    this module directly.
    """

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

    @doc "Always fails, simulating a client that has gone away."
    def chunk(_state, _chunk), do: {:error, :closed}
  end

  defmodule Datastar.Plug.Test do
    @moduledoc """
    Test helpers for applications built on `Datastar.Plug`.

    A disconnected client is the *only* signal a Datastar stream gets
    that it should stop: nothing arrives, and the write fails. Testing
    that branch means forcing `Plug.Conn.chunk/2` to fail, which needs an
    adapter stub — so this library ships the stub rather than letting
    every consumer rediscover it.

    This module compiles only when the optional `:plug` dependency is
    present.

    ## Examples

        iex> conn = Plug.Test.conn(:get, "/") |> Datastar.Plug.Test.closed_conn()
        iex> conn |> Datastar.Plug.start() |> Datastar.Plug.send_comment("hi")
        {:error, :closed}

    """

    @doc """
    Returns `conn` with an adapter that starts a chunked response
    normally and then fails every chunk with `{:error, :closed}`.

    Request-body reading is unaffected, so a test can still read signals
    before starting the response (§9.6).
    """
    @spec closed_conn(Plug.Conn.t()) :: Plug.Conn.t()
    def closed_conn(%Plug.Conn{adapter: {_module, state}} = conn) do
      %{conn | adapter: {Datastar.Plug.Test.ClosedAdapter, state}}
    end
  end
end
