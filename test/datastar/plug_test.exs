defmodule Datastar.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  describe "start/2 (§10.2)" do
    test "sets exact SSE headers and enters :chunked state with status 200" do
      conn = :get |> conn("/stream") |> Datastar.Plug.start()

      assert conn.state == :chunked
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "content-length") == []
    end

    test "keep-alive on HTTP/1.1 only; absent on HTTP/2" do
      http1 = :get |> conn("/stream") |> Datastar.Plug.start()
      assert get_resp_header(http1, "connection") == ["keep-alive"]

      http2 =
        :get
        |> conn("/stream")
        |> Datastar.TestSupport.HTTP2Adapter.wrap()
        |> Datastar.Plug.start()

      assert get_resp_header(http2, "connection") == []
    end

    test "custom status is honored" do
      assert (:get |> conn("/stream") |> Datastar.Plug.start(status: 203)).status == 203
    end

    test "an already-sent response raises before any write" do
      sent = :get |> conn("/") |> Plug.Conn.send_resp(200, "done")

      assert_raise ArgumentError, ~r/already sent/, fn -> Datastar.Plug.start(sent) end
    end

    test "unknown options raise" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Datastar.Plug.start(conn(:get, "/"), compress: true)
      end
    end
  end
end
