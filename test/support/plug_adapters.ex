defmodule Datastar.TestSupport.PlugAdapters do
  @moduledoc """
  Helpers for the adapter shims below, which wrap `Plug.Adapters.Test.Conn`
  to simulate HTTP/2, a closed connection, or a failing body read.
  """

  @doc "Swaps a `Plug.Test` conn's adapter module for `adapter`, keeping its state."
  @spec wrap(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def wrap(%Plug.Conn{adapter: {_mod, state}} = conn, adapter) do
    %{conn | adapter: {adapter, state}}
  end
end

defmodule Datastar.TestSupport.HTTP2Adapter do
  @moduledoc """
  Test adapter shim: identical to `Plug.Adapters.Test.Conn` but reports
  the HTTP/2 protocol, for asserting protocol-dependent headers.
  """

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate chunk(state, chunk), to: Plug.Adapters.Test.Conn
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn

  def get_http_protocol(_state), do: :"HTTP/2"
end

defmodule Datastar.TestSupport.ClosedAdapter do
  @moduledoc """
  Test adapter shim: accepts `send_chunked` but fails every subsequent
  chunk with `{:error, :closed}`, simulating a disconnected client.
  """

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

  def chunk(_state, _chunk), do: {:error, :closed}
end

defmodule Datastar.TestSupport.ErrorBodyAdapter do
  @moduledoc """
  Test adapter shim: identical to `Plug.Adapters.Test.Conn` but fails
  every `read_req_body` call with `{:error, :timeout}`, simulating a
  transport error while reading the request body.
  """

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate chunk(state, chunk), to: Plug.Adapters.Test.Conn
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

  def read_req_body(_state, _opts), do: {:error, :timeout}
end

defmodule Datastar.TestSupport.RecordingAdapter do
  @moduledoc """
  Test adapter shim: reports every `chunk/2` call to the connection's
  owner process as `{:chunk_written, binary}` before delegating, so a
  test can assert on writes that the returned conn would otherwise be
  the only witness to — including a write that a raise discards.
  """

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

  @doc "Records the chunk against the owner process, then writes it normally."
  def chunk(%{owner: owner} = state, body) do
    send(owner, {:chunk_written, IO.iodata_to_binary(body)})
    Plug.Adapters.Test.Conn.chunk(state, body)
  end
end
