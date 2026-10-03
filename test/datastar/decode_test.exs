defmodule Datastar.DecodeTest do
  use ExUnit.Case, async: true

  alias Datastar.Decode

  doctest Datastar.Decode

  describe "event/1 with element events" do
    test "reinstates every omitted default" do
      assert {:ok, decoded} = Decode.event(Datastar.patch_elements("<p>x</p>"))

      assert decoded == %{
               type: :patch_elements,
               mode: :outer,
               namespace: :html,
               use_view_transition: false,
               retry_duration: 1_000,
               elements: "<p>x</p>"
             }
    end

    test "decodes every option dataline" do
      event =
        Datastar.patch_elements("<li>a</li>",
          selector: "#feed",
          mode: :append,
          namespace: :svg,
          use_view_transition: true,
          view_transition_selector: "#vt"
        )

      assert {:ok, decoded} = Decode.event(event)
      assert decoded.selector == "#feed"
      assert decoded.mode == :append
      assert decoded.namespace == :svg
      assert decoded.use_view_transition == true
      assert decoded.view_transition_selector == "#vt"
      assert decoded.elements == "<li>a</li>"
    end

    test "element content that looks like an option dataline stays content" do
      event = Datastar.patch_elements("mode inner\nselector #evil", selector: "#t")

      assert {:ok, decoded} = Decode.event(event)
      assert decoded.mode == :outer
      assert decoded.selector == "#t"
      assert decoded.elements == "mode inner\nselector #evil"
    end

    test "repeated elements datalines rejoin as multiline content" do
      event = Datastar.patch_elements("<ul>\n  <li>a</li>\n</ul>")

      assert {:ok, decoded} = Decode.event(event)
      assert decoded.elements == "<ul>\n  <li>a</li>\n</ul>"
    end

    test "a selector-only removal decodes with elements: nil" do
      assert {:ok, decoded} = Decode.event(Datastar.remove_elements("#gone"))

      assert decoded.type == :patch_elements
      assert decoded.mode == :remove
      assert decoded.selector == "#gone"
      assert decoded.elements == nil
    end

    test "a script event decodes as patch_elements, script element intact" do
      event = Datastar.execute_script("f()", auto_remove: false)

      assert {:ok, decoded} = Decode.event(event)
      assert decoded.type == :patch_elements
      assert decoded.mode == :append
      assert decoded.selector == "body"
      assert decoded.elements == "<script>f()</script>"
    end
  end

  describe "event/1 element errors" do
    test "an unknown dataline key" do
      assert {:error, {:unknown_dataline, "bogus"}} =
               Decode.event(%{event: "datastar-patch-elements", data: "bogus 1\nelements <p/>"})
    end

    test "a duplicated option dataline" do
      assert {:error, {:duplicate_dataline, "mode"}} =
               Decode.event(%{
                 event: "datastar-patch-elements",
                 data: "mode inner\nmode append\nelements <p/>"
               })
    end

    test "an invalid enum value" do
      assert {:error, {:invalid_value, "mode", "sideways"}} =
               Decode.event(%{event: "datastar-patch-elements", data: "mode sideways"})
    end

    test "an invalid boolean value" do
      assert {:error, {:invalid_value, "useViewTransition", "yes"}} =
               Decode.event(%{
                 event: "datastar-patch-elements",
                 data: "useViewTransition yes\nelements <p/>"
               })
    end

    test "a dataline with no space" do
      assert {:error, :invalid_dataline} =
               Decode.event(%{event: "datastar-patch-elements", data: "mode"})
    end

    test "no elements and no selector-based removal" do
      assert {:error, :missing_elements} =
               Decode.event(%{event: "datastar-patch-elements", data: "mode remove"})
    end

    test "an unknown event type reports what a client would have seen" do
      assert {:error, {:unknown_event, "chat"}} = Decode.event(%{event: "chat", data: "hi"})
      assert {:error, {:unknown_event, "message"}} = Decode.event(%{data: "hi"})
    end

    test "non-map input is a programming error, not bad data" do
      assert_raise ArgumentError, ~r/semantic SSE event map/, fn -> Decode.event("data: x") end
    end

    test "a map with no :data is a programming error" do
      assert_raise ArgumentError, ~r/:data/, fn ->
        Decode.event(%{event: "datastar-patch-elements"})
      end
    end
  end
end
