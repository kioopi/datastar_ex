defmodule Datastar.Plug.StreamTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
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
      #
      # Asserting on `conn.state` would prove nothing: `conn` is bound before
      # the call and %Plug.Conn{} is immutable, so it reads :unset whatever
      # run/3 did. `Plug.Conn.send_chunked/2` posting {:plug_conn, :sent} is
      # the observable, and this fails the moment start/2 moves ahead of
      # subscribe.
      refute_received {:plug_conn, :sent}
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

  defp encoded(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()

  # Sends `count` ignorable messages roughly a millisecond apart. The sleep
  # generates a message *rate*, which is the subject of the heartbeat test
  # below; the test process itself never sleeps.
  defp feed(pid, count) do
    Enum.each(1..count, fn _ ->
      send(pid, :ignore)
      Process.sleep(1)
    end)
  end

  defp counting_handle({:patch, n}, state),
    do: {:patch, Datastar.patch_signals(%{"n" => n}), state}

  defp counting_handle(:stop, state), do: {:halt, state}
  defp counting_handle(_other, state), do: {:noreply, state}

  describe "run/3 loop" do
    test "processes queued messages in order, then halts" do
      send(self(), {:patch, 1})
      send(self(), {:patch, 2})
      send(self(), :stop)

      conn = Stream.run(conn(:get, "/"), :state, handle: &counting_handle/2)

      assert conn.resp_body ==
               encoded(Datastar.patch_signals(%{"n" => 1})) <>
                 encoded(Datastar.patch_signals(%{"n" => 2}))
    end

    test "threads state through decisions" do
      handle = fn
        :inc, n -> {:noreply, n + 1}
        :report, n -> {:halt, Datastar.patch_signals(%{"n" => n}), n}
        _other, n -> {:noreply, n}
      end

      send(self(), :inc)
      send(self(), :inc)
      send(self(), :report)

      conn = Stream.run(conn(:get, "/"), 0, handle: handle)

      assert conn.resp_body == encoded(Datastar.patch_signals(%{"n" => 2}))
    end

    test "a list of events is written as one chunk" do
      events = [Datastar.patch_signals(%{"a" => 1}), Datastar.patch_signals(%{"b" => 2})]

      handle = fn
        :go, state -> {:halt, events, state}
        _other, state -> {:noreply, state}
      end

      send(self(), :go)

      conn = Stream.run(conn(:get, "/"), :state, handle: handle)

      assert conn.resp_body == Enum.map_join(events, &encoded/1)
    end

    test "an empty event list writes nothing and continues" do
      handle = fn
        :empty, state -> {:patch, [], state}
        :stop, state -> {:halt, state}
        _other, state -> {:noreply, state}
      end

      send(self(), :empty)
      send(self(), :stop)

      assert Stream.run(conn(:get, "/"), :state, handle: handle).resp_body == ""
    end

    # nil is outside event_or_events(), and the likely cause is a render
    # function that returned nothing. Silently writing nothing would turn
    # that bug into a stream that stops updating with no error, so it
    # raises. {:noreply, state} already expresses a deliberate no-op.
    test "a nil event raises rather than silently writing nothing" do
      handle = fn
        :nothing, state -> {:patch, nil, state}
        _other, state -> {:noreply, state}
      end

      send(self(), :nothing)

      assert_raise ArgumentError, ~r/nil/, fn ->
        Stream.run(conn(:get, "/"), :state, handle: handle)
      end
    end

    test "a failed write halts the loop and returns the conn" do
      send(self(), {:patch, 1})
      send(self(), {:patch, 2})

      conn =
        conn(:get, "/")
        |> Datastar.Plug.Test.closed_conn()
        |> Stream.run(:state, handle: &counting_handle/2)

      assert %Plug.Conn{} = conn
    end

    test "an invalid decision raises with a message naming the return value" do
      handle = fn _message, _state -> :not_a_decision end

      send(self(), :go)

      assert_raise ArgumentError, ~r/:not_a_decision/, fn ->
        Stream.run(conn(:get, "/"), :state, handle: handle)
      end
    end

    test "the stream is semantically decodable" do
      send(self(), {:patch, 7})
      send(self(), :stop)

      conn = Stream.run(conn(:get, "/"), :state, handle: &counting_handle/2)

      {[parsed], _rest} = ServerSentEvents.Parser.parse(conn.resp_body)

      assert {:ok, %{type: :patch_signals, signals: ~s({"n":7})}} = Datastar.decode(parsed)
    end
  end

  # Deliberately has no catch-all clause: it raises FunctionClauseError on
  # any message other than :stop. That is what makes it a detector.
  defp strict_handle(:stop, state), do: {:halt, state}

  describe "run/3 and infrastructure messages" do
    test "{:plug_conn, :sent} never reaches the handler" do
      me = self()

      # on_start runs after start/2, so :stop lands in the mailbox *behind*
      # the {:plug_conn, :sent} that start/2 posted.
      conn =
        Stream.run(conn(:get, "/"), :state,
          on_start: fn state ->
            send(me, :stop)
            {:noreply, state}
          end,
          handle: &strict_handle/2
        )

      assert %Plug.Conn{state: :chunked} = conn
    end

    test "the mailbox really does contain {:plug_conn, :sent} after start/2" do
      Datastar.Plug.start(conn(:get, "/"))

      assert_received {:plug_conn, :sent}
    end
  end

  describe "run/3 heartbeat" do
    test "writes a keep-alive comment on timeout, and halts when the write fails" do
      conn =
        conn(:get, "/")
        |> Datastar.TestSupport.PlugAdapters.wrap(Datastar.TestSupport.FailAfterFirstChunkAdapter)
        |> Stream.run(:state, handle: &strict_handle/2, heartbeat: 5)

      # One newline, not two: a comment is not an event, so it carries no
      # blank-line terminator. See Datastar.SSE.encode_comment/1's doctest.
      assert conn.resp_body == ": keep-alive\n"
    end

    # The heartbeat exists to keep bytes on the wire, so its deadline must be
    # driven by writes, not by receives. A stream fed messages faster than the
    # heartbeat whose handler ignores them writes nothing, and a receive-reset
    # timer would never fire — silently the buffering-proxy death the default
    # exists to prevent. The feeder's Process.sleep generates a message rate;
    # it is the subject of the test, not synchronisation for it, and the test
    # process never sleeps.
    test "keeps writing keep-alives while ignored messages keep arriving" do
      me = self()
      feeder = spawn_link(fn -> feed(me, 600) end)

      handle = fn :ignore, state ->
        Process.put(:seen, Process.get(:seen, 0) + 1)
        {:noreply, state}
      end

      conn =
        conn(:get, "/")
        |> Datastar.TestSupport.PlugAdapters.wrap(Datastar.TestSupport.FailAfterFirstChunkAdapter)
        |> Stream.run(:state, handle: handle, heartbeat: 20)

      Process.unlink(feeder)
      Process.exit(feeder, :kill)

      assert conn.resp_body == ": keep-alive\n"

      # The discriminator, and the whole point of the test. A write-driven
      # deadline writes its first keep-alive about 20ms in, having seen only a
      # few dozen of the 600 messages, and halts on the second. A
      # receive-reset timer is held off by every arriving message, so it could
      # not write until the feed had finished - by which point it would have
      # seen all 600.
      assert Process.get(:seen, 0) < 200
    end

    test "an application message named :timeout reaches the handler" do
      handle = fn
        :timeout, state -> {:halt, Datastar.patch_signals(%{"got" => "timeout"}), state}
        _other, state -> {:noreply, state}
      end

      send(self(), :timeout)

      conn = Stream.run(conn(:get, "/"), :state, handle: handle, heartbeat: :infinity)

      assert conn.resp_body == encoded(Datastar.patch_signals(%{"got" => "timeout"}))
    end
  end

  describe "run/3 handler crashes" do
    test "logs the offending message, then re-raises" do
      handle = fn
        {:boom, _payload}, _state -> raise "handler exploded"
        _other, state -> {:noreply, state}
      end

      send(self(), {:boom, "details"})

      log =
        capture_log(fn ->
          assert_raise RuntimeError, "handler exploded", fn ->
            Stream.run(conn(:get, "/"), :state, handle: handle)
          end
        end)

      assert log =~ ~s({:boom, "details"})
    end

    test "logs a raising on_start too" do
      log =
        capture_log(fn ->
          assert_raise RuntimeError, "snapshot exploded", fn ->
            Stream.run(conn(:get, "/"), :state,
              handle: &strict_handle/2,
              on_start: fn _state -> raise "snapshot exploded" end
            )
          end
        end)

      assert log =~ "on_start"
    end

    test "bounds the logged message so a large payload is not dumped whole" do
      payload = String.duplicate("x", 5_000)

      handle = fn
        {:boom, _payload}, _state -> raise "handler exploded"
        _other, state -> {:noreply, state}
      end

      send(self(), {:boom, payload})

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn ->
            Stream.run(conn(:get, "/"), :state, handle: handle)
          end
        end)

      refute log =~ payload
      assert String.length(log) < 2_000
    end
  end
end
