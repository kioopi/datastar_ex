defmodule Datastar.Plug.TestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  doctest Datastar.Plug.Test

  test "send_chunked/2 still succeeds on a closed conn" do
    conn = conn(:get, "/") |> Datastar.Plug.Test.closed_conn()

    assert %Plug.Conn{state: :chunked} = Datastar.Plug.start(conn)
  end

  test "every chunk after the response starts fails with {:error, :closed}" do
    conn =
      conn(:get, "/")
      |> Datastar.Plug.Test.closed_conn()
      |> Datastar.Plug.start()

    assert {:error, :closed} = Datastar.Plug.send_event(conn, Datastar.patch_signals(%{"a" => 1}))
    assert {:error, :closed} = Datastar.Plug.send_comment(conn, "keep-alive")
  end

  test "reading the request body still works, so signals can be read first" do
    conn =
      conn(:post, "/", ~s({"a":1}))
      |> Datastar.Plug.Test.closed_conn()

    assert {:ok, %{"a" => 1}, _conn} = Datastar.Plug.Signals.read_signals(conn)
  end
end
