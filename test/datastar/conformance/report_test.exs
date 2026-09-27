defmodule Datastar.Conformance.ReportTest do
  use ExUnit.Case, async: true

  alias Datastar.Conformance.Report

  @golden ".conformance/datastar-v1.0.4/sdk/tests/golden"
  @checkout_present File.dir?(@golden)
  @checkout_skip if @checkout_present, do: false, else: "run `bash scripts/conformance` once"

  describe "cases/1" do
    @tag :conformance_checkout
    @tag skip: @checkout_skip
    test "reads every golden case with input and expected output" do
      cases = Report.cases(@golden)

      assert Enum.count_until(cases, 16) == 16
      assert Enum.any?(cases, &(&1.name == "patchElementsWithAllOptions" and &1.method == :get))
      assert Enum.any?(cases, &(&1.method == :post))

      for c <- cases do
        assert %{"events" => [_ | _]} = c.input
        assert c.expected_sse =~ "event:"
      end

      assert cases == Enum.sort_by(cases, &{&1.method, &1.name})
    end

    test "raises loudly on a missing or empty golden dir" do
      assert_raise RuntimeError, ~r/golden/, fn -> Report.cases("/nonexistent") end
    end

    @tag :tmp_dir
    test "raises loudly when the golden dir exists but has no cases", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "get"))
      File.mkdir_p!(Path.join(tmp, "post"))

      assert_raise RuntimeError, ~r/no golden cases/, fn -> Report.cases(tmp) end
    end
  end

  describe "analyze/3" do
    @names ~w(patchElementsWithAllOptions sendTwoEvents patchSignalsWithDefaults)

    test "exit 0 means every case passed regardless of log content" do
      assert Report.analyze("PASS", 0, @names) == %{result: :pass, failed: []}
    end

    test "a failed run attributes failures by FAIL lines; the rest pass" do
      log = File.read!("test/support/fixtures/runner_fail.log")

      assert Report.analyze(log, 1, @names) ==
               %{result: :fail, failed: ["patchElementsWithAllOptions", "sendTwoEvents"]}
    end

    test "a non-zero exit without FAIL lines is an infrastructure error" do
      assert_raise RuntimeError, ~r/infrastructure/, fn ->
        Report.analyze("panic: connection refused", 2, @names)
      end
    end

    test "FAIL lines naming unknown cases are ignored for attribution" do
      log = "--- FAIL: TestSSEGetEndpoints/someNewUpstreamCase (0.1s)\nFAIL"
      assert_raise RuntimeError, ~r/infrastructure/, fn -> Report.analyze(log, 1, @names) end
    end
  end

  describe "generate/1" do
    @tag :conformance_checkout
    @tag skip: @checkout_skip
    @tag :tmp_dir
    test "writes both artifacts with metadata and per-case rows", %{tmp_dir: tmp} do
      md = Path.join(tmp, "conformance.md")
      json = Path.join(tmp, "conformance.json")

      :ok =
        Report.generate(
          golden_dir: @golden,
          runner_log: "test/support/fixtures/runner_pass.log",
          exit_code: 0,
          out_md: md,
          out_json: json,
          tag: "v1.0.4"
        )

      md_content = File.read!(md)
      assert md_content =~ "# Datastar v1.0.4 conformance record"
      assert md_content =~ "**PASS ("
      assert md_content =~ "| patchElementsWithAllOptions | GET | pass |"
      assert md_content =~ "### sendTwoEvents (GET)"
      refute md_content =~ "TODO"

      decoded = JSON.decode!(File.read!(json))
      assert decoded["result"] == "pass"
      assert decoded["datastar_tag"] == "v1.0.4"
      assert is_binary(decoded["library_commit"])
      assert Enum.all?(decoded["cases"], &(&1["result"] == "pass"))
    end
  end
end
