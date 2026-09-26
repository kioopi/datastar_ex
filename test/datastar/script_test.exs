defmodule Datastar.ScriptTest do
  use ExUnit.Case, async: true

  alias Datastar.Script

  doctest Datastar.Script

  defp encoded(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()

  describe "execute/2 expansion (§8.2)" do
    test "defaults: body-append element patch with auto-removal" do
      assert Script.execute("console.log('hi')") == %{
               event: "datastar-patch-elements",
               data:
                 "selector body\nmode append\n" <>
                   ~s(elements <script data-effect="el.remove\(\)">console.log\('hi'\)</script>)
             }
    end

    test "auto_remove: false omits data-effect" do
      assert Script.execute("f()", auto_remove: false).data ==
               "selector body\nmode append\nelements <script>f()</script>"
    end

    test "explicit auto_remove: true equals omission" do
      assert Script.execute("f()", auto_remove: true) == Script.execute("f()")
    end

    test "attributes render sorted by name regardless of construction order (§8.3)" do
      event =
        Script.execute("f()",
          auto_remove: false,
          attributes: %{"type" => "module", "async" => ""}
        )

      assert event.data ==
               ~s(selector body\nmode append\nelements <script async="" type="module">f\(\)</script>)
    end

    test "attribute values are escaped for the attribute context" do
      event =
        Script.execute("f()",
          auto_remove: false,
          attributes: %{"data-x" => ~s(a & b < c > "d)}
        )

      assert event.data =~ ~s(data-x="a &amp; b &lt; c &gt; &quot;d")
    end

    test "valid name shapes are accepted" do
      attrs = %{"data-x" => "1", "xml:lang" => "en", "x_y.z" => "1", :type => "module"}
      event = Script.execute("f()", auto_remove: false, attributes: attrs)

      assert event.data =~ ~s(data-x="1" type="module" x_y.z="1" xml:lang="en")
    end

    test "invalid attribute names, values, and shapes are rejected (§8.6)" do
      for bad_name <- ["", "a b", "a\"b", "a>b", "a\nb"] do
        assert_raise ArgumentError, ~r/invalid attribute name/, fn ->
          Script.execute("f()", attributes: %{bad_name => "v"})
        end
      end

      assert_raise ArgumentError, ~r/attributes must be a map/, fn ->
        Script.execute("f()", attributes: [type: "module"])
      end

      assert_raise ArgumentError, ~r/UTF-8 binary value/, fn ->
        Script.execute("f()", attributes: %{"type" => :module})
      end
    end

    test "duplicate normalized names are rejected" do
      assert_raise ArgumentError, ~r/duplicate attribute name "type"/, fn ->
        Script.execute("f()", attributes: %{:type => "a", "type" => "b"})
      end
    end

    test "data-effect is reserved while auto_remove is true, free otherwise" do
      assert_raise ArgumentError, ~r/data-effect is reserved/, fn ->
        Script.execute("f()", attributes: %{"data-effect" => "el.remove()"})
      end

      assert Script.execute("f()", auto_remove: false, attributes: %{"data-effect" => "x()"}).data =~
               ~s(data-effect="x\(\)")
    end

    # Review Focus 3: reservation applies after name normalization.
    test "an atom-keyed data-effect hits the reservation too" do
      assert_raise ArgumentError, ~r/data-effect is reserved/, fn ->
        Script.execute("f()", attributes: %{"data-effect": "x()"})
      end
    end

    test "every case variation of </script is neutralized (§8.4)" do
      for tag <- ["</script", "</SCRIPT", "</ScRiPt"] do
        event = Script.execute("var s = '#{tag}>';", auto_remove: false)

        # Exactly one case-insensitive `</script` survives: the real
        # closing tag. The injected breakout sequence is neutralized.
        assert [_one_match] = Regex.scan(~r{</script}i, event.data)

        # The original casing survives after the inserted backslash.
        assert event.data =~ "<\\/" <> String.slice(tag, 2..-1//1)
      end
    end

    test "multiline scripts become multiple elements datalines" do
      event = Script.execute("line1();\nline2();", auto_remove: false)

      assert event.data ==
               "selector body\nmode append\n" <>
                 "elements <script>line1();\nelements line2();</script>"
    end

    test "Unicode and empty scripts are accepted; invalid source is rejected" do
      assert Script.execute("console.log('héllo → 世界')", auto_remove: false).data =~ "héllo → 世界"
      assert Script.execute("", auto_remove: false).data =~ "<script></script>"
      # apply/3 keeps the static type checker from flagging this
      # deliberately ill-typed call under --warnings-as-errors; the
      # ArgumentError still comes from execute/2's runtime validation.
      assert_raise ArgumentError, fn -> :erlang.apply(Script, :execute, [nil]) end
      assert_raise ArgumentError, fn -> Script.execute(<<0xFF>>) end
    end

    test "shared event options forward through the expansion; invalid options rejected" do
      event = Script.execute("f()", auto_remove: false, event_id: "e1", retry_duration: 2_000)
      assert event.id == "e1"
      assert event.retry == 2_000

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Script.execute("f()", selector: "#x")
      end

      assert_raise ArgumentError, ~r/:auto_remove/, fn ->
        Script.execute("f()", auto_remove: "no")
      end
    end

    test "the exact §8.5 example" do
      event =
        Script.execute(
          "console.log('hello')",
          auto_remove: false,
          attributes: %{"type" => "module"},
          event_id: "event-1",
          retry_duration: 2_000
        )

      assert event == %{
               event: "datastar-patch-elements",
               id: "event-1",
               retry: 2_000,
               data:
                 "selector body\nmode append\n" <>
                   ~s(elements <script type="module">console.log\('hello'\)</script>)
             }

      assert encoded(event) ==
               "event: datastar-patch-elements\nid: event-1\nretry: 2000\n" <>
                 "data: selector body\ndata: mode append\n" <>
                 ~s(data: elements <script type="module">console.log\('hello'\)</script>) <>
                 "\n\n"
    end
  end
end
