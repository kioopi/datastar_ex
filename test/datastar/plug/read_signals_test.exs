defmodule Datastar.Plug.ReadSignalsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  doctest Datastar.Plug.ReadSignals

  defp call(conn, opts \\ []) do
    Datastar.Plug.ReadSignals.call(conn, Datastar.Plug.ReadSignals.init(opts))
  end

  test "assigns the decoded signals" do
    conn = call(conn(:post, "/", ~s({"count":2})))

    assert conn.assigns.datastar_signals == %{"count" => 2}
  end

  test "assigns an empty map when there are no signals" do
    assert call(conn(:get, "/")).assigns.datastar_signals == %{}
  end

  test "reads the datastar query parameter on GET" do
    conn = call(conn(:get, "/?datastar=%7B%22a%22%3A1%7D"))

    assert conn.assigns.datastar_signals == %{"a" => 1}
  end

  test "returns a conn whose body has already been read, so start/2 can follow" do
    conn = call(conn(:post, "/", ~s({"a":1})))

    assert %Plug.Conn{state: :chunked} = Datastar.Plug.start(conn)
  end

  test "raises Signals.Error on malformed input" do
    error = assert_raise Datastar.Plug.Signals.Error, fn -> call(conn(:post, "/", "nope")) end

    assert error.reason == :invalid_json
    assert Plug.Exception.status(error) == 400
  end

  test "passes options through to read_signals!/2" do
    error =
      assert_raise Datastar.Plug.Signals.Error, fn ->
        call(conn(:post, "/", ~s({"a":"xxxxxxxxxx"})), max_length: 5)
      end

    assert error.reason == :too_large
  end

  test "rejects unknown options at init" do
    assert_raise ArgumentError, fn -> Datastar.Plug.ReadSignals.init(bogus: 1) end
  end
end
