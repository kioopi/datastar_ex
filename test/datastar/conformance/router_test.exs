defmodule Datastar.Conformance.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Datastar.Conformance.Router

  @opts Router.init([])

  defp request(conn), do: Router.call(conn, @opts)

  defp get_events(events) do
    payload = URI.encode_www_form(JSON.encode!(%{"events" => events}))
    request(conn(:get, "/test?datastar=" <> payload))
  end

  test "GET /test emits the described event as SSE with a 200" do
    conn = get_events([%{"type" => "patchElements", "elements" => "<div>Hi</div>"}])

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]

    assert conn.resp_body ==
             "event: datastar-patch-elements\ndata: elements <div>Hi</div>\n\n"
  end

  test "POST /test reads the events from the JSON body (readSignalsFromBody shape)" do
    payload =
      JSON.encode!(%{"events" => [%{"type" => "patchSignals", "signals" => %{"one" => 1}}]})

    conn =
      :post
      |> conn("/test", payload)
      |> request()

    assert conn.status == 200
    assert conn.resp_body == "event: datastar-patch-signals\ndata: signals {\"one\":1}\n\n"
  end

  test "sendTwoEvents: array order is wire order" do
    conn =
      get_events([
        %{"type" => "patchElements", "elements" => "<i>1</i>"},
        %{"type" => "patchElements", "elements" => "<i>2</i>"}
      ])

    assert conn.resp_body ==
             "event: datastar-patch-elements\ndata: elements <i>1</i>\n\n" <>
               "event: datastar-patch-elements\ndata: elements <i>2</i>\n\n"
  end

  test "all-options fixtures round through every dataline" do
    conn =
      get_events([
        %{
          "type" => "patchElements",
          "elements" => "<div>Merge</div>",
          "selector" => "div",
          "mode" => "append",
          "useViewTransition" => true,
          "viewTransitionSelector" => "#main",
          "namespace" => "svg",
          "eventId" => "event1",
          "retryDuration" => 2000
        }
      ])

    assert conn.resp_body ==
             "event: datastar-patch-elements\nid: event1\nretry: 2000\n" <>
               "data: selector div\ndata: mode append\ndata: useViewTransition true\n" <>
               "data: viewTransitionSelector #main\ndata: namespace svg\n" <>
               "data: elements <div>Merge</div>\n\n"
  end

  test "signal and element removal fixtures work end to end" do
    removal =
      get_events([%{"type" => "patchElements", "mode" => "remove", "selector" => "#obsolete"}])

    assert removal.resp_body ==
             "event: datastar-patch-elements\ndata: selector #obsolete\ndata: mode remove\n\n"

    nulls = get_events([%{"type" => "patchSignals", "signals" => %{"one" => nil}}])
    assert nulls.resp_body == "event: datastar-patch-signals\ndata: signals {\"one\":null}\n\n"
  end

  test "malformed fixtures get a 400 before SSE" do
    bad_type = get_events([%{"type" => "mergeFragments"}])
    assert bad_type.status == 400
    refute bad_type.resp_body =~ "event:"

    bad_json = request(conn(:get, "/test?datastar=%7Bnope"))
    assert bad_json.status == 400
  end

  # Review Focus 4: valid JSON that is not an object → 400 before SSE.
  test "a non-object datastar payload is a 400" do
    conn = request(conn(:get, "/test?datastar=" <> URI.encode_www_form("[1,2]")))
    assert conn.status == 400
    assert Plug.Conn.get_resp_header(conn, "content-type") != ["text/event-stream"]
  end

  test "the server module boots Bandit and serves /healthz" do
    {:ok, pid} = Datastar.Conformance.Server.start(0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    {:ok, {{_v, 200, _reason}, _headers, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/healthz", []}, [], [])

    assert to_string(body) == "ok"
    GenServer.stop(pid)
  end
end
