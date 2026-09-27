defmodule Datastar.PlugLifecycleTest do
  use ExUnit.Case, async: true

  alias Datastar.TestSupport.RawClient

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
end
