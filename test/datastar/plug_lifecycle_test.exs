defmodule Datastar.PlugLifecycleTest do
  use ExUnit.Case, async: true

  alias Datastar.TestSupport.LifecyclePlug
  alias Datastar.TestSupport.RawClient

  defp start_lifecycle_server do
    pid = start_supervised!({Bandit, plug: {LifecyclePlug, self()}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp start_conformance_server do
    pid = start_supervised!({Bandit, plug: Datastar.Conformance.Router, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # Sends events until the transport reports an error (bounded); returns it.
  defp send_until_error(handler) do
    Enum.reduce_while(1..10, :no_reply, fn _attempt, _acc ->
      send(handler, {:event, Datastar.patch_elements("<i>post</i>")})

      receive do
        {:sent, {:error, reason}} -> {:halt, {:error, reason}}
        {:sent, {:ok, _conn}} -> {:cont, :no_reply}
      after
        2_000 -> {:halt, :no_reply}
      end
    end)
  end

  describe "RawClient against a real Bandit server" do
    test "reads status, headers, and body over a real socket" do
      port = start_conformance_server()

      {:ok, client} = RawClient.connect(port)
      :ok = RawClient.get(client, "/healthz")

      {:ok, 200, headers, client} = RawClient.read_response_head(client)
      assert is_map(headers)

      # /healthz is a plain (non-chunked) response; drain what arrives.
      {:ok, body, _client} = RawClient.read_available(client, 5_000)
      assert body =~ "ok"
    end

    test "reads a chunked SSE response chunk by chunk from /test" do
      port = start_conformance_server()

      payload =
        URI.encode_www_form(
          JSON.encode!(%{"events" => [%{"type" => "patchElements", "elements" => "<i>x</i>"}]})
        )

      {:ok, client} = RawClient.connect(port)
      # connection: close so the completed response is followed by EOF —
      # under keep-alive the socket legitimately stays open.
      :ok = RawClient.get(client, "/test?datastar=" <> payload, [{"connection", "close"}])

      {:ok, 200, headers, client} = RawClient.read_response_head(client)
      assert headers["content-type"] == "text/event-stream"
      assert headers["transfer-encoding"] == "chunked"

      {:ok, chunk, client} = RawClient.read_chunk(client)
      assert chunk == "event: datastar-patch-elements\ndata: elements <i>x</i>\n\n"

      assert {:done, client} = RawClient.read_chunk(client)
      assert RawClient.recv_eof?(client, 5_000)
    end
  end

  describe "lifecycle over Bandit (§13.3)" do
    test "each event is delivered before the stream completes (immediate flush)" do
      port = start_lifecycle_server()
      {:ok, client} = RawClient.connect(port)
      :ok = RawClient.get(client, "/stream")

      assert_receive {:handler, handler}, 5_000
      assert_receive :started, 5_000
      {:ok, 200, headers, client} = RawClient.read_response_head(client)
      assert headers["content-type"] == "text/event-stream"
      assert headers["cache-control"] == "no-cache"
      assert headers["connection"] == "keep-alive"

      e1 = Datastar.patch_elements("<i>1</i>")
      send(handler, {:event, e1})
      assert_receive {:sent, {:ok, _conn}}, 5_000

      # The event is on the wire NOW — before any further event exists.
      {:ok, chunk, client} = RawClient.read_chunk(client)
      assert chunk == IO.iodata_to_binary(Datastar.SSE.encode(e1))

      e2 = Datastar.patch_signals(%{n: 2})
      send(handler, {:event, e2})
      assert_receive {:sent, {:ok, _conn}}, 5_000
      {:ok, chunk, client} = RawClient.read_chunk(client)
      assert chunk == IO.iodata_to_binary(Datastar.SSE.encode(e2))

      send(handler, :finish)
      assert_receive :finished, 5_000
      assert {:done, client} = RawClient.read_chunk(client)
      # Request was keep-alive (so the response-header assertion above is
      # meaningful); the stream is complete when the zero-chunk arrives and
      # nothing further follows — the socket itself may stay open for reuse.
      assert {:error, :timeout} = RawClient.read_available(client, 300)
    end

    test "heartbeat comments arrive but dispatch no events" do
      port = start_lifecycle_server()
      {:ok, client} = RawClient.connect(port)
      :ok = RawClient.get(client, "/stream")
      assert_receive {:handler, handler}, 5_000
      assert_receive :started, 5_000
      {:ok, 200, _headers, client} = RawClient.read_response_head(client)

      send(handler, {:comment, "keep-alive"})
      assert_receive {:sent, {:ok, _conn}}, 5_000
      {:ok, comment_chunk, client} = RawClient.read_chunk(client)
      assert comment_chunk == ": keep-alive\n"

      event = Datastar.patch_elements("<i>x</i>")
      send(handler, {:event, event})
      assert_receive {:sent, {:ok, _conn}}, 5_000
      {:ok, event_chunk, client} = RawClient.read_chunk(client)

      send(handler, :finish)
      assert {:done, _client} = RawClient.read_chunk(client)

      # Oracle: the full byte stream dispatches exactly one event.
      decoded =
        [comment_chunk <> event_chunk]
        |> ServerSentEvents.decode_stream()
        |> Enum.to_list()

      assert decoded == [event]
    end

    test "an aborted client makes a subsequent send_event return {:error, reason}" do
      port = start_lifecycle_server()
      {:ok, client} = RawClient.connect(port)
      :ok = RawClient.get(client, "/stream")
      assert_receive {:handler, handler}, 5_000
      assert_receive :started, 5_000
      {:ok, 200, _headers, client} = RawClient.read_response_head(client)

      # One successful send proves the stream is live.
      send(handler, {:event, Datastar.patch_elements("<i>pre</i>")})
      assert_receive {:sent, {:ok, _conn}}, 5_000
      {:ok, _chunk, client} = RawClient.read_chunk(client)

      ref = Process.monitor(handler)
      :ok = RawClient.abort(client)

      # RST makes failure prompt, but TCP is asynchronous: allow a bounded
      # number of sends for the error to surface (Review Focus 1).
      assert {:error, reason} = send_until_error(handler)
      # Observed value is :closed on Bandit 1.x/Linux. Deliberately not
      # accepting is_binary(reason): Bandit maps ANY non-transport exception
      # to {:error, Exception.message(...)} (a binary), so that arm would
      # also pass for an unrelated write-path crash.
      assert reason in [:closed, :econnreset, :epipe]

      # The handler returns its conn and the connection process winds down.
      assert_receive {:DOWN, ^ref, :process, ^handler, down_reason}, 5_000
      # Observed value is {:shutdown, _} (not bare :normal/:shutdown) on
      # this setup — :normal would also admit the handler's unrelated
      # after-timeout path, so it is deliberately excluded.
      assert match?({:shutdown, _}, down_reason)
    end

    test "after a disconnect the listener serves fresh requests and leaks no handler" do
      port = start_lifecycle_server()

      # First connection: abort mid-stream.
      {:ok, client} = RawClient.connect(port)
      :ok = RawClient.get(client, "/stream")
      assert_receive {:handler, first_handler}, 5_000
      assert_receive :started, 5_000
      {:ok, 200, _headers, client} = RawClient.read_response_head(client)
      ref = Process.monitor(first_handler)
      :ok = RawClient.abort(client)

      # A single send can land in the kernel buffer and report {:ok, _}
      # (FIN/RST asynchrony), leaving the handler re-blocked in its receive
      # loop with no DOWN ever arriving. Retry (bounded) until the transport
      # actually reports the error, as in the disconnect-error test above.
      assert {:error, reason} = send_until_error(first_handler)
      assert reason in [:closed, :econnreset, :epipe]

      assert_receive {:DOWN, ^ref, :process, ^first_handler, down_reason}, 5_000
      assert match?({:shutdown, _}, down_reason)
      refute Process.alive?(first_handler)

      # Second connection: full clean lifecycle on the same listener
      # (connection: close so completion is observable as EOF).
      {:ok, client2} = RawClient.connect(port)
      :ok = RawClient.get(client2, "/stream", [{"connection", "close"}])
      assert_receive {:handler, second_handler}, 5_000
      assert second_handler != first_handler
      assert_receive :started, 5_000
      {:ok, 200, _headers, client2} = RawClient.read_response_head(client2)
      send(second_handler, :finish)
      assert_receive :finished, 5_000
      assert {:done, client2} = RawClient.read_chunk(client2)
      assert RawClient.recv_eof?(client2, 5_000)
    end

    test "a client reading in arbitrarily small pieces still decodes the stream" do
      port = start_lifecycle_server()
      {:ok, client} = RawClient.connect(port)
      # connection: close so drain below observes true EOF — under
      # keep-alive the socket legitimately stays open (as established in
      # the flush test above).
      :ok = RawClient.get(client, "/stream", [{"connection", "close"}])
      assert_receive {:handler, handler}, 5_000
      assert_receive :started, 5_000
      {:ok, 200, _headers, client} = RawClient.read_response_head(client)

      e1 = Datastar.patch_elements("<div>\n  <span>Hi</span>\n</div>")
      e2 = Datastar.patch_signals(%{"a" => 1})

      for event <- [e1, e2] do
        send(handler, {:event, event})
        assert_receive {:sent, {:ok, _conn}}, 5_000
      end

      send(handler, :finish)
      assert_receive :finished, 5_000

      # Drain the socket in whatever fragments the kernel hands us, then
      # dechunk and feed the oracle one byte at a time.
      #
      # drain/2 loops RawClient.read_available/2 until it errors, and that
      # error IS the EOF observation: OTP's gen_tcp reports a closed
      # connection exactly once as {:error, :closed}. Any recv issued
      # afterward — e.g. a second, independent RawClient.recv_eof?/2 call
      # on the same socket — instead returns {:error, :enotconn}, so
      # drain's own terminal reason is what we assert on here rather than
      # re-probing the socket (observed on OTP 29 / gen_tcp).
      {raw, _client, close_reason} = drain(client, "")
      assert close_reason == :closed

      body = dechunk(raw)

      decoded =
        body
        |> :binary.bin_to_list()
        |> Enum.map(&<<&1>>)
        |> ServerSentEvents.decode_stream()
        |> Enum.to_list()

      assert decoded == [e1, e2]
    end
  end

  defp drain(client, acc) do
    case RawClient.read_available(client, 5_000) do
      {:ok, data, client} ->
        drain(client, acc <> data)

      {:error, reason} ->
        {acc, client, reason}
    end
  end

  defp dechunk(raw) do
    # Reassemble chunked-transfer payload from a fully drained response.
    dechunk(raw, "")
  end

  defp dechunk(rest, acc) do
    case :binary.split(rest, "\r\n") do
      ["0", _trailer] ->
        acc

      [size_hex, more] ->
        {size, ""} = Integer.parse(size_hex, 16)
        <<data::binary-size(^size), "\r\n", tail::binary>> = more
        dechunk(tail, acc <> data)
    end
  end
end
