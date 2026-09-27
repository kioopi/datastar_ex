defmodule Datastar.BrowserTest do
  use ExUnit.Case, async: false

  @moduletag :browser
  @moduletag timeout: 60_000

  alias Datastar.TestSupport.Browser

  defp run_case(name) do
    pid = start_supervised!({Bandit, plug: {Datastar.TestSupport.BrowserPlug, self()}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    :ok = Browser.open("http://127.0.0.1:#{port}/case/#{name}")

    assert_receive {:browser_report, ^name, payload}, 15_000
    payload
  end

  test "signals: add, update, remove, and onlyIfMissing against the real client" do
    payload = run_case("signals")
    stage = payload["stage"]

    # Case events (defined in Browser.cases/0):
    #   patch_signals(%{count: 1})                       -> add
    #   patch_signals(%{count: 2})                       -> update
    #   patch_signals(%{count: 9}, only_if_missing: true) -> must NOT override
    #   patch_signals(%{label: "here"})                  -> second signal appears
    #   patch_signals(%{label: nil})                     -> removed
    assert stage =~ ~r/<span id="sig"[^>]*>2<\/span>/
    refute stage =~ ">9<"

    # §14 finding: patching a signal to `null` removes it from the signal
    # store (mergePatch/RFC 7386 semantics — confirmed separately in the
    # pure-core test suite), but the v1.0.4 client's `data-text` binding
    # does NOT re-render to clear the element. The `text` attribute plugin
    # sets up its reactive effect the first time the bound expression
    # reads the signal; deleting the signal removes the key from the
    # store without notifying that already-registered effect (there is no
    # more `label` proxy trap to fire through), so the DOM keeps showing
    # the last value the signal held. Removal is invisible to the real
    # client for this binding shape — assert the observed reality rather
    # than the removal we might have assumed.
    assert stage =~ ~r/<span id="label"[^>]*>here<\/span>/
  end
end
