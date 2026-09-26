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

  describe "patch/2 (JSON-native maps, §7.1)" do
    test "a map encodes to compact JSON and equals the patch_raw equivalent (§12.1)" do
      event = Signals.patch(%{count: 2}, only_if_missing: true)

      assert event == %{
               event: "datastar-patch-signals",
               data: ~s(onlyIfMissing true\nsignals {"count":2})
             }

      assert event == Signals.patch_raw(JSON.encode!(%{count: 2}), only_if_missing: true)
    end

    test "string, atom, and integer keys normalize to JSON member names" do
      assert Signals.patch(%{"a" => 1}).data == ~s(signals {"a":1})
      assert Signals.patch(%{a: 1}).data == ~s(signals {"a":1})
      assert Signals.patch(%{1 => "x"}).data == ~s(signals {"1":"x"})
    end

    test "nil values encode to null (signal removal, §7.5)" do
      assert Signals.patch(%{"one" => nil}).data == ~s(signals {"one":null})

      event = Signals.patch(%{"two" => %{"alpha" => nil}})
      assert event.data == ~s(signals {"two":{"alpha":null}})
    end

    test "the exact §7.5 removing-signals example" do
      assert Signals.patch(%{"one" => nil, "two" => %{"alpha" => nil}}) ==
               %{
                 event: "datastar-patch-signals",
                 data: ~s(signals {"one":null,"two":{"alpha":null}})
               }
    end

    # Review Focus 2: an empty object is a valid no-op merge patch.
    test "an empty map is accepted and produces signals {}" do
      assert Signals.patch(%{}) == %{event: "datastar-patch-signals", data: "signals {}"}
    end

    test "nested maps, lists, and Unicode values encode" do
      assert Signals.patch(%{"s" => "wörld"}).data == ~s(signals {"s":"wörld"})

      assert Signals.patch(%{"l" => [1, "a", nil, true]}).data ==
               ~s(signals {"l":[1,"a",null,true]})

      assert Signals.patch(%{"n" => %{"m" => [%{"k" => 1.5}]}}).data ==
               ~s(signals {"n":{"m":[{"k":1.5}]}})
    end

    test "non-map input and structs are rejected at every depth" do
      for bad <- [nil, "json", 42, [a: 1], ~D[2026-09-26]] do
        assert_raise ArgumentError, fn -> Signals.patch(bad) end
      end

      assert_raise ArgumentError, ~r/unsupported JSON value/, fn ->
        Signals.patch(%{"when" => ~D[2026-09-26]})
      end

      assert_raise ArgumentError, ~r/unsupported JSON value/, fn ->
        Signals.patch(%{"deep" => %{"date" => [~D[2026-09-26]]}})
      end
    end

    test "unsupported value terms are rejected" do
      for bad <- [:atom_value, {:tuple, 1}, self(), make_ref(), fn -> :x end] do
        assert_raise ArgumentError, ~r/unsupported JSON value/, fn ->
          Signals.patch(%{"v" => bad})
        end
      end
    end

    test "improper lists are rejected" do
      assert_raise ArgumentError, ~r/proper list/, fn -> Signals.patch(%{"l" => [1 | 2]}) end
    end

    test "unsupported key types and malformed binaries are rejected" do
      assert_raise ArgumentError, ~r/map keys/, fn -> Signals.patch(%{1.5 => "x"}) end
      assert_raise ArgumentError, ~r/UTF-8/, fn -> Signals.patch(%{<<0xFF>> => "x"}) end
      assert_raise ArgumentError, ~r/UTF-8/, fn -> Signals.patch(%{"k" => <<0xFF>>}) end
    end

    test "normalized key collisions are rejected at any depth (§7.1)" do
      assert_raise ArgumentError, ~r/duplicate JSON member name "count"/, fn ->
        Signals.patch(%{:count => 1, "count" => 2})
      end

      assert_raise ArgumentError, ~r/duplicate JSON member name/, fn ->
        Signals.patch(%{"outer" => %{:x => 1, "x" => 2}})
      end
    end

    # Review Focus 4: integer/string collisions are collisions too.
    test "integer and string keys colliding after normalization are rejected" do
      assert_raise ArgumentError, ~r/duplicate JSON member name "1"/, fn ->
        Signals.patch(%{1 => "a", "1" => "b"})
      end
    end
  end
end
