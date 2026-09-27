defmodule Datastar.Conformance.Router do
  @moduledoc """
  Executable `/test` endpoint for the official Datastar SDK conformance
  runner (SDK core spec §11.1): reads the fixture through the public
  signal-reading boundary, builds every event before starting SSE, sends
  them in order, and finishes the response so the runner reads EOF.

  Conformance infrastructure, not a recommended application API.
  """

  use Plug.Router

  alias Datastar.Conformance.Dispatcher

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, System.get_env("CONFORMANCE_NONCE", "ok"))
  end

  get "/test" do
    handle(conn)
  end

  post "/test" do
    handle(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp handle(conn) do
    case Datastar.Plug.Signals.read_signals(conn) do
      {:ok, signals, conn} ->
        case Dispatcher.events(signals) do
          {:ok, events} -> stream(conn, events)
          {:error, message} -> send_resp(conn, 400, message)
        end

      {:error, reason, conn} ->
        send_resp(conn, 400, "invalid signals: #{inspect(reason)}")
    end
  end

  defp stream(conn, events) do
    conn = Datastar.Plug.start(conn)
    Enum.reduce(events, conn, &Datastar.Plug.send_event!(&2, &1))
  end
end
