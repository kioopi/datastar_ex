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
    #   Elements.patch(<span id="label-after" data-text="$label">, append) -> I3 fresh binding
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

    # I3: positive removal evidence. `#label-after` is inserted by an
    # element patch that runs AFTER `label` was removed, so its
    # `data-text="$label"` binding is processed fresh against the current
    # signal store rather than reusing an effect registered while `label`
    # still existed. Observed reality (headless Chrome, this client
    # build): the freshly-bound element renders EMPTY, not "here" and not
    # the literal string "undefined" — the `text` plugin's reactive effect
    # evaluates `$label` against a store that no longer has the key at
    # all, unlike `#label` above (bound before removal, stuck on the last
    # value it ever saw). That contrast is the positive proof the null
    # patch actually deleted the signal rather than merely failing to
    # notify an existing binding.
    assert stage =~ ~r/<span id="label-after" data-text="\$label"><\/span>/
  end

  test "patch modes: outer (+view transition), inner, remove, replace, prepend, append, before, after" do
    payload = run_case("modes")
    stage = payload["stage"]

    # Case events (defined in Browser.cases/0):
    #   outer patch (use_view_transition: true) morphs #m-outer in place
    refute stage =~ "outer-old"
    assert stage =~ ~r/<div id="m-outer" class="after">outer-new<\/div>/

    # inner patch replaces only #m-inner's children; the wrapper stays
    assert stage =~ ~r/<div id="m-inner"><span>inner-new<\/span><\/div>/
    refute stage =~ "inner-old"

    # remove patch: the element is gone entirely
    refute stage =~ "m-remove"

    # replace patch: outerHTML swap
    refute stage =~ "replace-old"
    assert stage =~ ~r/<div id="m-replace" class="replaced">replace-new<\/div>/

    # prepend: new <li> lands before the original one
    {prepend_new, _} = :binary.match(stage, "prepended")
    {prepend_orig, _} = :binary.match(stage, "orig-prepend")
    assert prepend_new < prepend_orig

    # append: new <li> lands after the original one
    {append_new, _} = :binary.match(stage, "appended")
    {append_orig, _} = :binary.match(stage, "orig-append")
    assert append_new > append_orig

    # before: new sibling lands ahead of the anchor
    {before_new, _} = :binary.match(stage, "before-new")
    {before_anchor, _} = :binary.match(stage, "anchor-before")
    assert before_new < before_anchor

    # after: new sibling lands behind the anchor
    {after_new, _} = :binary.match(stage, "after-new")
    {after_anchor, _} = :binary.match(stage, "anchor-after")
    assert after_new > after_anchor
  end

  test "SVG and MathML namespaces are preserved by namespace-tagged patches" do
    payload = run_case("namespaces")
    probe = payload["probe"]

    # Case events (defined in Browser.cases/0):
    #   patch("<circle .../>", selector: "#svg-root", mode: :inner, namespace: :svg)
    #   patch("<mi>x</mi>", selector: "#math-root", mode: :inner, namespace: :mathml)
    # The case's __probe override reads back the live element's namespaceURI.
    assert probe["circleNS"] == "http://www.w3.org/2000/svg"
    assert probe["miNS"] == "http://www.w3.org/1998/Math/MathML"
  end

  test "multiline elements, multiline raw signals, and two ordered appends" do
    payload = run_case("multiline")
    stage = payload["stage"]

    # Case events (defined in Browser.cases/0):
    #   outer patch with an embedded-newline <div> (template-shaped)
    #   patch_raw with pretty-printed (multiline) JSON
    #   two append patches, "first" then "second", to the same list
    assert stage =~ ~r/<p>line one<\/p>\s*<p>line two<\/p>/
    assert stage =~ ~r/<span id="ml-sig"[^>]*>multiline-signal<\/span>/

    {first_pos, _} = :binary.match(stage, "first")
    {second_pos, _} = :binary.match(stage, "second")
    assert first_pos < second_pos
  end

  test "executeScript runs with auto_remove default and auto_remove: false" do
    payload = run_case("scripts")
    stage = payload["stage"]
    probe = payload["probe"]

    # Case events (defined in Browser.cases/0):
    #   Script.execute(...)                      -> auto_remove: true (default)
    #   Script.execute(..., auto_remove: false)  -> stays in the DOM
    # Both scripts ran: their DOM markers are visible in #stage.
    assert stage =~ ~r/<div id="script-out-1"[^>]*>ran-1<\/div>/
    assert stage =~ ~r/<div id="script-out-2"[^>]*>ran-2<\/div>/

    # I2/M5: `#stage` doesn't capture body-appended <script> elements at all
    # (they live outside it), so the case's __probe reads the surviving
    # non-src body scripts' textContent directly, filtered to our markers.
    # `__report()` runs two rAFs after the events stream finishes, and by
    # that time the `auto_remove: true` script (script-out-1) has already
    # run its `data-effect="el.remove()"` removal effect and is gone from
    # the DOM; only the `auto_remove: false` script (script-out-2, never
    # removed) remains. The old version of this probe counted raw
    # `<script>` elements including the reporter's own still-executing
    # `window.__report()` script and miscounted; reading identities instead
    # of a count makes the assertion honest about what's actually left.
    assert [remaining] = probe["scripts"]
    assert remaining =~ "script-out-2"
  end
end
