defmodule Datastar.TestSupport.Browser do
  @moduledoc """
  Headless-Chrome launcher and per-case event definitions for the §14
  browser smoke tests. Chrome is a dumb executor: pages self-report the
  resulting DOM via POST /report, and `timeout 30` reaps every launch.
  Requires google-chrome-stable (or $BROWSER_BIN) on PATH; the suite is
  excluded from the default test run — use `mise run test:browser`.
  """

  alias Datastar.Signals

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
      }
    }
  end
end
