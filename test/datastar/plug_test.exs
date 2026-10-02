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
        |> Datastar.TestSupport.PlugAdapters.wrap(Datastar.TestSupport.HTTP2Adapter)
        |> Datastar.Plug.start()

      assert get_resp_header(http2, "connection") == []
    end

    test "a pre-set content-length header is removed (spec §10.2)" do
      conn =
        :get
        |> conn("/stream")
        |> Plug.Conn.put_resp_header("content-length", "5")
        |> Datastar.Plug.start()

      assert get_resp_header(conn, "content-length") == []
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

  describe "send_event/2 (§10.1, §10.3)" do
    test "writes exactly Datastar.SSE.encode/1's bytes as one chunk" do
      event = Datastar.patch_elements("<i>x</i>", event_id: "1")

      {:ok, conn} =
        :get
        |> conn("/stream")
        |> Datastar.Plug.start()
        |> Datastar.Plug.send_event(event)

      assert conn.resp_body == event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
    end

    test "sequential events preserve order in the body" do
      e1 = Datastar.patch_elements("<i>1</i>")
      e2 = Datastar.patch_signals(%{n: 2})

      # Accumulating every chunk into conn.resp_body is a Plug.Test
      # adapter detail for assertions here, not part of chunk/2's public
      # contract (a real adapter streams chunks; it does not buffer them).
      conn = :get |> conn("/stream") |> Datastar.Plug.start()
      {:ok, conn} = Datastar.Plug.send_event(conn, e1)
      {:ok, conn} = Datastar.Plug.send_event(conn, e2)

      expected =
        IO.iodata_to_binary([Datastar.SSE.encode(e1), Datastar.SSE.encode(e2)])

      assert conn.resp_body == expected
    end

    test "an invalid event raises ArgumentError before writing" do
      conn = :get |> conn("/stream") |> Datastar.Plug.start()

      assert_raise ArgumentError, fn -> Datastar.Plug.send_event(conn, %{}) end
      assert_raise ArgumentError, fn -> Datastar.Plug.send_event(conn, %{data: "x", bogus: 1}) end
    end

    test "transport errors propagate as {:error, reason}" do
      conn =
        :get
        |> conn("/stream")
        |> Datastar.Plug.start()
        |> Datastar.TestSupport.PlugAdapters.wrap(Datastar.TestSupport.ClosedAdapter)

      assert Datastar.Plug.send_event(conn, %{data: "x"}) == {:error, :closed}
    end

    test "send_event!/2 raises TransportError carrying the reason" do
      conn =
        :get
        |> conn("/stream")
        |> Datastar.Plug.start()
        |> Datastar.TestSupport.PlugAdapters.wrap(Datastar.TestSupport.ClosedAdapter)

      err =
        assert_raise Datastar.Plug.TransportError, ~r/:closed/, fn ->
          Datastar.Plug.send_event!(conn, %{data: "x"})
        end

      assert err.reason == :closed
    end

    test "comments use encode_comment/1 and never terminate an event" do
      conn = :get |> conn("/stream") |> Datastar.Plug.start()
      {:ok, conn} = Datastar.Plug.send_comment(conn, "keep-alive")

      assert conn.resp_body == ": keep-alive\n"
    end

    test "sending before start/2 fails predictably" do
      assert_raise ArgumentError, fn ->
        Datastar.Plug.send_event(conn(:get, "/"), %{data: "x"})
      end
    end
  end
end
