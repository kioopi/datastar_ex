defmodule Datastar.ElementsTest do
  use ExUnit.Case, async: true

  alias Datastar.Elements

  doctest Datastar.Elements

  defp encoded(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()

  describe "patch/2 minimal" do
    test "single-line elements produce one elements dataline" do
      event = Elements.patch(~s(<div id="feed">Hello</div>))

      assert event == %{
               event: "datastar-patch-elements",
               data: ~s(elements <div id="feed">Hello</div>)
             }

      assert encoded(event) ==
               "event: datastar-patch-elements\ndata: elements <div id=\"feed\">Hello</div>\n\n"
    end
  end

  describe "patch/2 options and ordering" do
    test "all non-default options together, canonical dataline order (§6.3)" do
      event =
        Elements.patch(
          "<li>New</li>",
          selector: "#feed",
          mode: :append,
          use_view_transition: true,
          view_transition_selector: "#main",
          namespace: :svg,
          event_id: "event-1",
          retry_duration: 2_000
        )

      assert event == %{
               event: "datastar-patch-elements",
               id: "event-1",
               retry: 2_000,
               data:
                 "selector #feed\nmode append\nuseViewTransition true\n" <>
                   "viewTransitionSelector #main\nnamespace svg\nelements <li>New</li>"
             }
    end

    test "the exact §6.7 'patch with options' example" do
      assert Elements.patch(
               "<li>New</li>",
               selector: "#feed",
               mode: :append,
               use_view_transition: true,
               namespace: :html,
               event_id: "event-1",
               retry_duration: 2_000
             ) == %{
               event: "datastar-patch-elements",
               id: "event-1",
               retry: 2_000,
               data: "selector #feed\nmode append\nuseViewTransition true\nelements <li>New</li>"
             }
    end

    test "every non-default mode emits its dataline" do
      for mode <- [:inner, :replace, :prepend, :append, :before, :after] do
        assert Elements.patch("<i>x</i>", mode: mode).data ==
                 "mode #{mode}\nelements <i>x</i>"
      end
    end

    test "each default explicitly supplied equals omission (§3.5)" do
      base = Elements.patch("<i>x</i>")
      assert Elements.patch("<i>x</i>", mode: :outer) == base
      assert Elements.patch("<i>x</i>", namespace: :html) == base
      assert Elements.patch("<i>x</i>", use_view_transition: false) == base
      assert Elements.patch("<i>x</i>", retry_duration: 1_000) == base
    end

    test "every non-default namespace emits its dataline" do
      assert Elements.patch("<circle/>", namespace: :svg).data ==
               "namespace svg\nelements <circle/>"

      assert Elements.patch("<mi>x</mi>", namespace: :mathml).data ==
               "namespace mathml\nelements <mi>x</mi>"
    end

    test "empty event id and zero retry are preserved (§5.2)" do
      assert Elements.patch("<i>x</i>", event_id: "") ==
               %{event: "datastar-patch-elements", id: "", data: "elements <i>x</i>"}

      assert Elements.patch("<i>x</i>", retry_duration: 0) ==
               %{event: "datastar-patch-elements", retry: 0, data: "elements <i>x</i>"}
    end
  end

  describe "patch/2 normalization (§6.4)" do
    test "multiline LF, CRLF, CR, and mixed input normalize identically" do
      expected = "elements <div>\nelements   <span>Hi</span>\nelements </div>"

      for html <- [
            "<div>\n  <span>Hi</span>\n</div>",
            "<div>\r\n  <span>Hi</span>\r\n</div>",
            "<div>\r  <span>Hi</span>\r</div>",
            "<div>\r\n  <span>Hi</span>\n</div>"
          ] do
        assert Elements.patch(html).data == expected
      end
    end

    test "interior empty lines are preserved as empty elements datalines" do
      event = Elements.patch("<div>\n\n</div>")
      assert event.data == "elements <div>\nelements \nelements </div>"
      assert encoded(event) =~ "data: elements \n"
    end

    test "trailing newlines and whitespace-only lines are trimmed" do
      expected = %{event: "datastar-patch-elements", data: "elements <div>Ready</div>"}
      assert Elements.patch("<div>Ready</div>") == expected
      assert Elements.patch("<div>Ready</div>\n") == expected
      assert Elements.patch("<div>Ready</div>\n   \n") == expected
      assert Elements.patch("<div>Ready</div>\r\n \t\f\r\n") == expected
    end

    test "whitespace on the final retained line is preserved" do
      assert Elements.patch("  <div>x</div>  ").data == "elements   <div>x</div>  "
    end

    # Review Focus 1: only CR, LF, CRLF are line breaks.
    test "Unicode separators U+2028, U+0085, U+000B are content, not line breaks" do
      for sep <- ["\u2028", "\u0085", "\u000B"] do
        assert Elements.patch("a#{sep}b").data == "elements a#{sep}b"
      end
    end

    # Review Focus 5: nested iodata flattens; invalid iodata raises ArgumentError.
    test "nested iodata flattens before splitting" do
      assert Elements.patch(["<div>", [?a | "b"], ["</", "div>"]]).data ==
               "elements <div>ab</div>"
    end

    test "non-ASCII HTML passes through" do
      assert Elements.patch("<p>héllo → 世界</p>").data == "elements <p>héllo → 世界</p>"
    end
  end

  describe "remove/2 (§6.5)" do
    test "removal by selector emits no elements dataline" do
      event = Elements.remove("#obsolete")

      assert event == %{
               event: "datastar-patch-elements",
               data: "selector #obsolete\nmode remove"
             }

      assert encoded(event) ==
               "event: datastar-patch-elements\ndata: selector #obsolete\ndata: mode remove\n\n"
    end

    test "shared options pass through" do
      assert Elements.remove("#x", event_id: "7", retry_duration: 0) == %{
               event: "datastar-patch-elements",
               id: "7",
               retry: 0,
               data: "selector #x\nmode remove"
             }
    end

    test "conflicting :mode or :selector options are rejected" do
      assert_raise ArgumentError, ~r/remove\/2 fixes :mode/, fn ->
        Elements.remove("#x", mode: :append)
      end

      assert_raise ArgumentError, ~r/remove\/2 fixes :mode/, fn ->
        Elements.remove("#x", mode: :remove)
      end

      assert_raise ArgumentError, ~r/remove\/2 fixes :selector/, fn ->
        Elements.remove("#x", selector: "#y")
      end
    end

    test "non-keyword options are rejected" do
      assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
        # credo:disable-for-lines:1 Credo.Check.Refactor.Apply
        apply(Elements, :remove, ["#x", %{event_id: "1"}])
      end
    end
  end

  describe "patch/2 validation (§6.6)" do
    test "input that is empty after trimming is rejected outside removal" do
      for input <- [nil, "", "\n", "  \n \t\n"] do
        assert_raise ArgumentError, ~r/elements are required/, fn ->
          Elements.patch(input)
        end
      end
    end

    test "removal via patch/2 requires a selector" do
      assert_raise ArgumentError, ~r/elements are required/, fn ->
        Elements.patch(nil, mode: :remove)
      end

      assert Elements.patch(nil, mode: :remove, selector: "#x").data ==
               "selector #x\nmode remove"
    end

    test "invalid iodata raises ArgumentError" do
      for bad <- [[:atom], %{}, [999_999], 42] do
        assert_raise ArgumentError, fn -> Elements.patch(bad) end
      end
    end

    test "malformed UTF-8 raises" do
      assert_raise ArgumentError, ~r/UTF-8/, fn -> Elements.patch(<<0xFF, 0xFE>>) end
    end

    test "string modes and namespaces are rejected" do
      assert_raise ArgumentError, ~r/:mode/, fn -> Elements.patch("<i>x</i>", mode: "append") end

      assert_raise ArgumentError, ~r/:namespace/, fn ->
        Elements.patch("<i>x</i>", namespace: "svg")
      end
    end

    test "atoms outside the enums are rejected" do
      assert_raise ArgumentError, ~r/:mode/, fn -> Elements.patch("<i>x</i>", mode: :merge) end

      assert_raise ArgumentError, ~r/:namespace/, fn ->
        Elements.patch("<i>x</i>", namespace: :xml)
      end
    end

    test "non-boolean view transition and nil option values are rejected" do
      assert_raise ArgumentError, ~r/:use_view_transition/, fn ->
        Elements.patch("<i>x</i>", use_view_transition: "true")
      end

      assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", selector: nil) end
      assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", mode: nil) end
      assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", use_view_transition: nil) end
    end

    test "view transition selector without use_view_transition: true is rejected" do
      assert_raise ArgumentError, ~r/requires use_view_transition/, fn ->
        Elements.patch("<i>x</i>", view_transition_selector: "#main")
      end

      assert_raise ArgumentError, ~r/requires use_view_transition/, fn ->
        Elements.patch("<i>x</i>", view_transition_selector: "#main", use_view_transition: false)
      end
    end

    test "selector injection characters are rejected, not stripped (§15.1)" do
      for bad <- ["#a\nelements <b>", "#a\rx", "#a\0", "\n", ""] do
        assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", selector: bad) end

        assert_raise ArgumentError, fn ->
          Elements.patch("<i>x</i>", use_view_transition: true, view_transition_selector: bad)
        end
      end
    end

    test "non-binary selectors and unknown/duplicate options are rejected" do
      assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", selector: :feed) end

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Elements.patch("<i>x</i>", merge: true)
      end

      assert_raise ArgumentError, ~r/duplicate option/, fn ->
        Elements.patch("<i>x</i>", [{:mode, :append}, {:mode, :inner}])
      end
    end

    test "options are validated before elements" do
      assert_raise ArgumentError, ~r/unknown option :merge/, fn ->
        Elements.patch(123, merge: true)
      end
    end
  end

  describe "security regressions (§15.1)" do
    test "a selector cannot forge a mode dataline" do
      assert_raise ArgumentError, fn ->
        Elements.patch("<i>x</i>", selector: "#a\nmode remove")
      end
    end

    test "element content cannot forge an SSE field: every line is re-prefixed" do
      event = Elements.patch("<i>x</i>\nevent: hacked\ndata: forged")

      assert event.data ==
               "elements <i>x</i>\nelements event: hacked\nelements data: forged"
    end
  end
end
