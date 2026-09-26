defmodule Datastar.SignalsTest do
  use ExUnit.Case, async: true

  alias Datastar.Signals

  doctest Datastar.Signals

  defp encoded(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()

  describe "patch_raw/2" do
    test "compact single-line JSON produces one signals dataline" do
      event = Signals.patch_raw(~s({"count":2}))

      assert event == %{event: "datastar-patch-signals", data: ~s(signals {"count":2})}

      assert encoded(event) ==
               "event: datastar-patch-signals\ndata: signals {\"count\":2}\n\n"
    end

    test "only_if_missing true prepends the dataline; false and omitted do not" do
      assert Signals.patch_raw("{}", only_if_missing: true).data ==
               "onlyIfMissing true\nsignals {}"

      assert Signals.patch_raw("{}", only_if_missing: false).data == "signals {}"
      assert Signals.patch_raw("{}").data == "signals {}"
    end

    test "multiline JSON: every line ending style, one dataline per line, trailing preserved (§7.3)" do
      for json <- ["{\n\"one\": 1\n}", "{\r\n\"one\": 1\r\n}", "{\r\"one\": 1\r}"] do
        assert Signals.patch_raw(json).data == "signals {\nsignals \"one\": 1\nsignals }"
      end

      assert Signals.patch_raw("{}\n").data == "signals {}\nsignals "
      assert Signals.patch_raw("{\n\n}").data == "signals {\nsignals \nsignals }"
    end

    test "escaped newline inside a JSON string stays on one dataline" do
      assert Signals.patch_raw(~s({"note":"a\\nb"})).data == ~s(signals {"note":"a\\nb"})
    end

    # Review Focus 1 (signals side): only CR/LF/CRLF split datalines.
    test "Unicode separators are content, not line breaks" do
      # Using a helper to build the string with U+2028
      json_with_sep = "{\"s\":\"a" <> <<0xE2, 0x80, 0xA8>> <> "b\"}"
      expected = "signals {\"s\":\"a" <> <<0xE2, 0x80, 0xA8>> <> "b\"}"
      assert Signals.patch_raw(json_with_sep).data == expected
    end

    test "Unicode JSON and null-removal payloads pass through" do
      assert Signals.patch_raw(~s({"héllo":"wörld"})).data == ~s(signals {"héllo":"wörld"})

      assert Signals.patch_raw(~s({"one":null,"two":{"alpha":null}})).data ==
               ~s(signals {"one":null,"two":{"alpha":null}})
    end

    test "shared event options apply" do
      assert Signals.patch_raw("{}", event_id: "e1", retry_duration: 2_000) ==
               %{event: "datastar-patch-signals", id: "e1", retry: 2_000, data: "signals {}"}

      assert Signals.patch_raw("{}", retry_duration: 1_000) ==
               %{event: "datastar-patch-signals", data: "signals {}"}
    end

    test "invalid raw input is rejected (§7.6)" do
      # Test non-binary input
      assert_raise ArgumentError, ~r/binary/, fn ->
        # Use Tuple.to_list to hide type from static checker
        [bad_input] = Tuple.to_list({%{count: 2}})
        Signals.patch_raw(bad_input)
      end

      # Test invalid UTF-8
      assert_raise ArgumentError, ~r/UTF-8/, fn -> Signals.patch_raw(<<0xFF>>) end

      # Test empty input
      assert_raise ArgumentError, ~r/empty/, fn -> Signals.patch_raw("") end
    end

    test "invalid, unknown, and duplicate options are rejected" do
      assert_raise ArgumentError, ~r/:only_if_missing/, fn ->
        Signals.patch_raw("{}", only_if_missing: "yes")
      end

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Signals.patch_raw("{}", merge: true)
      end

      assert_raise ArgumentError, ~r/duplicate option/, fn ->
        Signals.patch_raw("{}", [{:only_if_missing, true}, {:only_if_missing, false}])
      end

      assert_raise ArgumentError, fn -> Signals.patch_raw("{}", event_id: "a\nb") end
      assert_raise ArgumentError, fn -> Signals.patch_raw("{}", retry_duration: -1) end
    end
  end
end
