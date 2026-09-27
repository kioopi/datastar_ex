defmodule Datastar.TestSupport.BrowserPlug do
  @moduledoc """
  Serves the §14 browser fixture pages: a self-reporting HTML page per
  case (`GET /case/:name`), the vendored client bundle (`GET
  /assets/datastar.js`), the case's SSE event stream with a reporter
  event appended (`GET /events?case=name`), and the report sink (`POST
  /report?case=name`) that forwards the decoded JSON payload to the test
  process as `{:browser_report, name, payload}`.

  Test support only — this is the harness the real client executes
  against, not application code.
  """

  @behaviour Plug

  import Plug.Conn

  alias Datastar.Script
  alias Datastar.TestSupport.Browser

  @asset_path Path.join(__DIR__, "assets/datastar.js")

  @page """
  <!doctype html>
  <html>
    <head><script type="module" src="/assets/datastar.js"></script></head>
    <body data-init="@get('/events?case=%CASE%')">
      <div id="stage">
  %STAGE%
      </div>
      <script>
        window.__probe ??= () => null; // cases override via their own markup/scripts
        window.__report = () => {
          requestAnimationFrame(() => requestAnimationFrame(() => {
            fetch('/report?case=%CASE%', {
              method: 'POST',
              headers: {'content-type': 'application/json'},
              body: JSON.stringify({
                stage: document.getElementById('stage').outerHTML,
                probe: window.__probe()
              })
            });
          }));
        };
      </script>
    </body>
  </html>
  """

  @impl true
  def init(test_pid), do: test_pid

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["case", name]} = conn, _test_pid) do
    serve_case(conn, name)
  end

  def call(%Plug.Conn{method: "GET", path_info: ["assets", "datastar.js"]} = conn, _test_pid) do
    serve_asset(conn)
  end

  def call(%Plug.Conn{method: "GET", path_info: ["events"]} = conn, _test_pid) do
    conn = fetch_query_params(conn)
    stream_case(conn, conn.query_params["case"])
  end

  def call(%Plug.Conn{method: "POST", path_info: ["report"]} = conn, test_pid) do
    conn = fetch_query_params(conn)
    receive_report(conn, conn.query_params["case"], test_pid)
  end

  def call(conn, _test_pid) do
    send_resp(conn, 404, "not found")
  end

  defp serve_case(conn, name) do
    case Browser.cases()[name] do
      %{stage: stage} ->
        body =
          @page
          |> String.replace("%STAGE%", stage)
          |> String.replace("%CASE%", name)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      nil ->
        send_resp(conn, 404, "unknown case: #{inspect(name)}")
    end
  end

  defp serve_asset(conn) do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, File.read!(@asset_path))
  end

  defp stream_case(conn, name) do
    case Browser.cases()[name] do
      %{events: events} ->
        conn = Datastar.Plug.start(conn)
        conn = Enum.reduce(events, conn, &Datastar.Plug.send_event!(&2, &1))
        Datastar.Plug.send_event!(conn, Script.execute("window.__report()", auto_remove: true))

      nil ->
        send_resp(conn, 404, "unknown case: #{inspect(name)}")
    end
  end

  defp receive_report(conn, name, test_pid) do
    {:ok, body, conn} = read_body(conn)
    payload = JSON.decode!(body)
    send(test_pid, {:browser_report, name, payload})
    send_resp(conn, 204, "")
  end
end
