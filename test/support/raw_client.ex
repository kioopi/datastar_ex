defmodule Datastar.TestSupport.RawClient do
  @moduledoc """
  Minimal raw-TCP HTTP/1.1 client for real-server lifecycle tests (SDK
  core spec §13.3): byte-honest reads of chunked transfer encoding, an
  RST-sending `abort/1` for deterministic disconnect tests, and explicit
  timeouts on every read so a hung socket fails the test instead of the
  suite. Test support only — deliberately not a general HTTP client.
  """

  defstruct [:socket, buffer: ""]

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), buffer: binary()}

  @doc "Connects to 127.0.0.1:port in binary passive mode."
  def connect(port) do
    with {:ok, socket} <-
           :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true]) do
      {:ok, %__MODULE__{socket: socket}}
    end
  end

  @doc """
  Sends a minimal HTTP/1.1 GET. Pass `{"connection", "close"}` in
  `headers` when the test needs the server to close the socket after the
  response — with the default keep-alive, a completed chunked response
  legitimately leaves the connection OPEN for reuse, so EOF assertions
  only make sense on connection-close requests.
  """
  def get(%__MODULE__{socket: socket}, path, headers \\ []) do
    headers =
      if List.keymember?(headers, "connection", 0),
        do: headers,
        else: [{"connection", "keep-alive"} | headers]

    extra = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n#{extra}\r\n")
  end

  @doc "Reads through the end of the response head; buffers any overshoot."
  def read_response_head(%__MODULE__{} = client, timeout \\ 5_000) do
    with {:ok, head, client} <- read_until(client, "\r\n\r\n", timeout) do
      [status_line | header_lines] = String.split(head, "\r\n", trim: true)
      [_http, status | _reason] = String.split(status_line, " ")

      headers =
        Map.new(header_lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      {:ok, String.to_integer(status), headers, client}
    end
  end

  @doc """
  Reads exactly one chunked-transfer chunk. `{:done, client}` on the
  terminating zero chunk. Loops the socket until the full chunk payload
  (size line + data + trailing CRLF) is buffered.
  """
  def read_chunk(%__MODULE__{} = client, timeout \\ 5_000) do
    with {:ok, size_line, client} <- read_until(client, "\r\n", timeout),
         {size, ""} <- Integer.parse(String.trim(size_line), 16) do
      read_chunk_body(client, size, timeout)
    else
      {:error, _reason} = error -> error
      _bad_size -> {:error, :bad_chunk_size}
    end
  end

  defp read_chunk_body(client, 0, timeout) do
    with {:ok, _trailer, client} <- read_exact(client, 2, timeout), do: {:done, client}
  end

  defp read_chunk_body(client, size, timeout) do
    with {:ok, data, client} <- read_exact(client, size, timeout),
         {:ok, "\r\n", client} <- read_exact(client, 2, timeout) do
      {:ok, data, client}
    end
  end

  @doc "Returns buffered bytes, or the next TCP segment if the buffer is empty."
  def read_available(%__MODULE__{buffer: ""} = client, timeout) do
    with {:ok, data} <- :gen_tcp.recv(client.socket, 0, timeout) do
      {:ok, data, client}
    end
  end

  def read_available(%__MODULE__{buffer: buffer} = client, _timeout) do
    {:ok, buffer, %{client | buffer: ""}}
  end

  @doc "Closes with a TCP RST (linger 0) — the deterministic disconnect."
  def abort(%__MODULE__{socket: socket}) do
    :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end

  @doc "Plain FIN close."
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  @doc "True when the connection is at EOF (buffer empty and recv reports closed)."
  def recv_eof?(%__MODULE__{buffer: ""} = client, timeout) do
    match?({:error, :closed}, :gen_tcp.recv(client.socket, 0, timeout))
  end

  def recv_eof?(%__MODULE__{}, _timeout), do: false

  defp read_until(%__MODULE__{buffer: buffer} = client, marker, timeout) do
    case :binary.split(buffer, marker) do
      [head, rest] ->
        {:ok, head, %{client | buffer: rest}}

      [_incomplete] ->
        with {:ok, data} <- :gen_tcp.recv(client.socket, 0, timeout) do
          read_until(%{client | buffer: buffer <> data}, marker, timeout)
        end
    end
  end

  defp read_exact(%__MODULE__{buffer: buffer} = client, size, timeout) do
    if byte_size(buffer) >= size do
      <<data::binary-size(^size), rest::binary>> = buffer
      {:ok, data, %{client | buffer: rest}}
    else
      with {:ok, more} <- :gen_tcp.recv(client.socket, 0, timeout) do
        read_exact(%{client | buffer: buffer <> more}, size, timeout)
      end
    end
  end
end
