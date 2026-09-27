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
    {:ok, pid} = Datastar.Conformance.Server.start(0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    # Bandit/ThousandIsland links its listener supervisor to the starting
    # process and self-terminates with reason :shutdown when that process
    # exits (observed on Bandit 1.12.5 / OTP 29) — by the time this on_exit
    # runs (a separate process, after the test process has already died),
    # the listener is already mid-shutdown. GenServer.stop's default reason
    # (:normal) then races that in-flight :shutdown and crashes with a
    # reason mismatch; passing :shutdown here matches the real teardown
    # path instead of fighting it.
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :shutdown) end)
    port
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
  end
end
