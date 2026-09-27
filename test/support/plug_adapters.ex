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

  @doc "Swaps a Plug.Test conn's adapter module for this one."
  def wrap(%Plug.Conn{adapter: {_mod, state}} = conn) do
    %{conn | adapter: {__MODULE__, state}}
  end
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

  def wrap(%Plug.Conn{adapter: {_mod, state}} = conn) do
    %{conn | adapter: {__MODULE__, state}}
  end
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

  @doc "Swaps a Plug.Test conn's adapter module for this one."
  def wrap(%Plug.Conn{adapter: {_mod, state}} = conn) do
    %{conn | adapter: {__MODULE__, state}}
  end
end
