defmodule Datastar.TestSupport.LifecyclePlug do
  @moduledoc """
  Test harness plug for real-server lifecycle tests (SDK core spec
  §13.3). The handler process registers itself with the test process and
  then performs exactly the sends the test instructs, reporting every
  transport result back — so event timing, stream completion, and
  disconnect behavior are all deterministic, message-coordinated facts
  rather than sleep-and-hope. Test support only.
  """

  @behaviour Plug

  @impl true
  def init(test_pid), do: test_pid

  @impl true
  def call(conn, test_pid) do
    send(test_pid, {:handler, self()})
    conn = Datastar.Plug.start(conn)
    send(test_pid, :started)
    loop(conn, test_pid)
  end

  defp loop(conn, test_pid) do
    receive do
      {:event, event} ->
        report_and_continue(Datastar.Plug.send_event(conn, event), test_pid, conn)

      {:comment, text} ->
        report_and_continue(Datastar.Plug.send_comment(conn, text), test_pid, conn)

      :finish ->
        send(test_pid, :finished)
        conn
    after
      10_000 -> conn
    end
  end

  # On a transport error the loop stops and returns the last good conn —
  # that pre-failure conn is what Plug expects back from call/2.
  defp report_and_continue(result, test_pid, conn) do
    send(test_pid, {:sent, result})

    case result do
      {:ok, updated_conn} -> loop(updated_conn, test_pid)
      {:error, _reason} -> conn
    end
  end
end
