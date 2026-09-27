defmodule Datastar.TestSupport.Browser do
  @moduledoc """
  Headless-Chrome launcher and per-case event definitions for the §14
  browser smoke tests. Chrome is a dumb executor: pages self-report the
  resulting DOM via POST /report, and `timeout 30` reaps every launch.
  Requires google-chrome-stable (or $BROWSER_BIN) on PATH; the suite is
  excluded from the default test run — use `mise run test:browser`.
  """

  alias Datastar.{Elements, Script, Signals}

  @doc """
  Launches headless Chrome against `url`, detached, reaped by `timeout
  30`. Chrome self-destructs its own throwaway profile directory once it
  exits. Raises if the browser binary is not on `PATH`.
  """
  @spec open(String.t()) :: :ok
  def open(url) do
    bin = System.get_env("BROWSER_BIN", "google-chrome-stable")

    System.find_executable(bin) ||
      raise "browser binary #{bin} not found — install Chrome or set BROWSER_BIN"

    profile =
      Path.join(System.tmp_dir!(), "datastar-browser-#{System.unique_integer([:positive])}")

    spawn(fn ->
      System.cmd(
        "timeout",
        ~w(30 #{bin} --headless=new --disable-gpu --no-sandbox --disable-dev-shm-usage) ++
          ["--user-data-dir=#{profile}", url],
        stderr_to_stdout: true
      )

      File.rm_rf(profile)
    end)

    :ok
  end

  @typedoc "One fixture case: its `#stage` markup and the events streamed before the reporter."
  @type case_definition :: %{events: [Datastar.SSE.event()], stage: String.t()}

  @doc """
  Per-case fixture definitions consumed by `Datastar.TestSupport.BrowserPlug`.

  Each case supplies the `#stage` markup rendered into the page and the
  ordered events streamed over `/events` (the plug appends the reporter
  event automatically — it is never listed here).
  """
  @spec cases() :: %{String.t() => case_definition()}
  def cases do
    %{
      "signals" => %{
        stage: """
        <div id="target">initial</div>
        <span id="sig" data-text="$count"></span>
        <span id="label" data-text="$label"></span>
        """,
        events: [
          # add
          Signals.patch(%{count: 1}),
          # update
          Signals.patch(%{count: 2}),
          # only_if_missing: true must NOT override the existing value
          Signals.patch(%{count: 9}, only_if_missing: true),
          # second signal appears
          Signals.patch(%{label: "here"}),
          # removed
          Signals.patch(%{label: nil})
        ]
      },
      "modes" => %{
        stage: """
        <div id="m-outer" class="before">outer-old</div>
        <div id="m-inner"><span>inner-old</span></div>
        <div id="m-remove">remove-me</div>
        <div id="m-replace">replace-old</div>
        <ul id="m-prepend"><li>orig-prepend</li></ul>
        <ul id="m-append"><li>orig-append</li></ul>
        <div id="m-before-anchor">anchor-before</div>
        <div id="m-after-anchor">anchor-after</div>
        """,
        events: [
          # outer (morph), with a view transition requested
          Elements.patch(~s(<div id="m-outer" class="after">outer-new</div>),
            selector: "#m-outer",
            mode: :outer,
            use_view_transition: true
          ),
          # inner: replace children only, wrapper stays
          Elements.patch("<span>inner-new</span>", selector: "#m-inner", mode: :inner),
          # remove: element disappears entirely
          Elements.patch(nil, selector: "#m-remove", mode: :remove),
          # replace: outerHTML swap
          Elements.patch(~s(<div id="m-replace" class="replaced">replace-new</div>),
            selector: "#m-replace",
            mode: :replace
          ),
          # prepend: new child before the existing one
          Elements.patch("<li>prepended</li>", selector: "#m-prepend", mode: :prepend),
          # append: new child after the existing one
          Elements.patch("<li>appended</li>", selector: "#m-append", mode: :append),
          # before: new sibling ahead of the anchor
          Elements.patch(~s(<div id="m-before-new">before-new</div>),
            selector: "#m-before-anchor",
            mode: :before
          ),
          # after: new sibling behind the anchor
          Elements.patch(~s(<div id="m-after-new">after-new</div>),
            selector: "#m-after-anchor",
            mode: :after
          )
        ]
      },
      "namespaces" => %{
        stage: """
        <svg id="svg-root"></svg>
        <math id="math-root"></math>
        <script>
          window.__probe = () => ({
            circleNS: document.querySelector('#svg-root circle')?.namespaceURI,
            miNS: document.querySelector('#math-root mi')?.namespaceURI
          });
        </script>
        """,
        events: [
          Elements.patch(~s(<circle cx="5" cy="5" r="5"/>),
            selector: "#svg-root",
            mode: :inner,
            namespace: :svg
          ),
          Elements.patch("<mi>x</mi>", selector: "#math-root", mode: :inner, namespace: :mathml)
        ]
      },
      "multiline" => %{
        stage: """
        <div id="ml-target"></div>
        <span id="ml-sig" data-text="$note"></span>
        <ul id="ml-list"></ul>
        """,
        events: [
          # multiline HTML patch: the embedded newlines survive as one element
          Elements.patch(
            """
            <div id="ml-target">
              <p>line one</p>
              <p>line two</p>
            </div>
            """,
            selector: "#ml-target",
            mode: :outer
          ),
          # multiline raw signal patch: pretty-printed JSON spans several
          # `signals` datalines that the client must reassemble before parsing
          Signals.patch_raw("""
          {
            "note": "multiline-signal"
          }
          """),
          # two ordered element patches appending <li>s to the same list
          Elements.patch("<li>first</li>", selector: "#ml-list", mode: :append),
          Elements.patch("<li>second</li>", selector: "#ml-list", mode: :append)
        ]
      },
      "scripts" => %{
        stage: """
        <div id="script-out-1"></div>
        <div id="script-out-2"></div>
        <script>
          window.__probe = () => ({
            scripts: document.querySelectorAll('body > script:not([src])').length
          });
        </script>
        """,
        events: [
          # default auto_remove: true — the <script> element removes itself
          Script.execute("document.getElementById('script-out-1').textContent = 'ran-1';"),
          # auto_remove: false — the <script> element stays in the DOM
          Script.execute(
            "document.getElementById('script-out-2').textContent = 'ran-2';",
            auto_remove: false
          )
        ]
      }
    }
  end
end
