defmodule Datastar.Plug.StreamTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Datastar.Plug.Stream

  doctest Datastar.Plug.Stream

  defp halt_handle(_message, state), do: {:halt, state}

  # Collects the next `count` {:step, _} messages in mailbox order, which is
  # what proves the prologue's ordering. The `after` is a failure timeout,
  # not synchronisation.
  defp steps(count) do
    for _ <- 1..count do
      receive do
        {:step, step} -> step
      after
        200 -> flunk("expected #{count} ordering steps")
      end
    end
  end

  describe "run/3 option validation" do
    test "rejects an unknown option" do
      assert_raise ArgumentError, fn ->
        Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, bogus: 1)
      end
    end

    test "requires :handle" do
      assert_raise ArgumentError, ~r/:handle/, fn ->
        Stream.run(conn(:get, "/"), :state, [])
      end
    end

    test "rejects a :handle of the wrong arity" do
      assert_raise ArgumentError, ~r/:handle/, fn ->
        Stream.run(conn(:get, "/"), :state, handle: fn _a, _b, _c -> :nope end)
      end
    end

    test "rejects an :on_start of the wrong arity" do
      assert_raise ArgumentError, ~r/:on_start/, fn ->
        Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, on_start: fn -> :nope end)
      end
    end

    test "rejects a :subscribe of the wrong arity" do
      assert_raise ArgumentError, ~r/:subscribe/, fn ->
        Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, subscribe: fn _x -> :nope end)
      end
    end

    test "rejects a :heartbeat that is neither a positive integer nor :infinity" do
      for bad <- [0, -1, "30s", nil] do
        assert_raise ArgumentError, ~r/:heartbeat/, fn ->
          Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, heartbeat: bad)
        end
      end
    end

    test "accepts :infinity as a heartbeat" do
      conn =
        Stream.run(conn(:get, "/"), :state,
          handle: &halt_handle/2,
          on_start: &{:halt, &1},
          heartbeat: :infinity
        )

      assert %Plug.Conn{state: :chunked} = conn
    end
  end

  describe "run/3 prologue" do
    test "runs subscribe before on_start" do
      me = self()

      Stream.run(conn(:get, "/"), :state,
        subscribe: fn -> send(me, {:step, :subscribe}) end,
        on_start: fn state ->
          send(me, {:step, :on_start})
          {:halt, state}
        end,
        handle: &halt_handle/2
      )

      assert steps(2) == [:subscribe, :on_start]
    end

    test "a raising subscribe propagates before the response is started" do
      conn = conn(:get, "/")

      assert_raise RuntimeError, "no topic", fn ->
        Stream.run(conn, :state, subscribe: fn -> raise "no topic" end, handle: &halt_handle/2)
      end

      # The response was never started, so a caller's error handler can still
      # produce a status. This is why subscribe runs first.
      assert conn.state == :unset
    end

    test "starts the chunked response" do
      conn = Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, on_start: &{:halt, &1})

      assert conn.state == :chunked
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "on_start can patch" do
      conn =
        Stream.run(conn(:get, "/"), :state,
          handle: &halt_handle/2,
          on_start: fn state -> {:halt, Datastar.patch_signals(%{"a" => 1}), state} end
        )

      assert conn.resp_body == "event: datastar-patch-signals\ndata: signals {\"a\":1}\n\n"
    end

    test "on_start can halt without writing" do
      conn = Stream.run(conn(:get, "/"), :state, handle: &halt_handle/2, on_start: &{:halt, &1})

      assert conn.resp_body == ""
    end
  end
end
