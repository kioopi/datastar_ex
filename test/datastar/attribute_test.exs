defmodule Datastar.AttributeTest do
  use ExUnit.Case, async: true

  alias Datastar.Attribute

  doctest Datastar.Attribute

  describe "attribute/3" do
    test "builds a plugin attribute with no key" do
      assert Attribute.attribute(:text, "$count") == {"data-text", "$count"}
    end

    test "builds a plugin attribute with a key, using the colon" do
      assert Attribute.attribute("on", "f()", key: "click") == {"data-on:click", "f()"}
    end

    test "appends modifiers after a double underscore" do
      assert Attribute.attribute("on", "f()", key: "click", modifiers: [debounce: "500ms"]) ==
               {"data-on:click__debounce.500ms", "f()"}
    end

    test "a valueless modifier has no dot" do
      assert Attribute.attribute("on", "f()", key: "click", modifiers: [:once]) ==
               {"data-on:click__once", "f()"}
    end

    test "modifiers keep their given order" do
      {name, _value} =
        Attribute.attribute("on", "f()", key: "click", modifiers: [:once, {:delay, "4s"}])

      assert name == "data-on:click__once__delay.4s"
    end

    test "a nil value is the empty string, for boolean-style attributes" do
      assert Attribute.attribute(:ignore, nil) == {"data-ignore", ""}
    end

    test "accepts every pinned plugin, including hyphenated ones" do
      for plugin <- Attribute.plugins() do
        assert {"data-" <> ^plugin, "x"} = Attribute.attribute(plugin, "x")
      end

      assert Attribute.attribute("on-intersect", "f()") == {"data-on-intersect", "f()"}
    end

    test "accepts every bare attribute without a key" do
      for attr <- Attribute.bare_attributes() do
        assert {"data-" <> ^attr, ""} = Attribute.attribute(attr, nil)
      end
    end

    test "rejects a key on a bare attribute, which has no plugin to key into" do
      assert_raise ArgumentError, ~r/bare attribute/, fn ->
        Attribute.attribute(:ignore, nil, key: "x")
      end
    end

    test "rejects an unknown plugin name" do
      assert_raise ArgumentError, ~r/unknown Datastar plugin/, fn ->
        Attribute.attribute("on-click", "f()")
      end
    end

    test "rejects a key containing the plugin separator characters" do
      assert_raise ArgumentError, fn -> Attribute.attribute("on", "f()", key: "cl:ick") end
      assert_raise ArgumentError, fn -> Attribute.attribute("on", "f()", key: "cl__ick") end
    end

    test "rejects a modifier name or argument containing a separator" do
      assert_raise ArgumentError, fn -> Attribute.attribute("on", "f()", modifiers: ["a__b"]) end

      assert_raise ArgumentError, fn ->
        Attribute.attribute("on", "f()", modifiers: [a: "b:c"])
      end
    end

    test "rejects CR, LF and NUL in the value" do
      for bad <- ["a\nb", "a\rb", "a\0b"] do
        assert_raise ArgumentError, fn -> Attribute.attribute(:text, bad) end
      end
    end

    test "rejects an unknown option" do
      assert_raise ArgumentError, fn -> Attribute.attribute(:text, "x", bogus: 1) end
    end

    test "does not HTML-escape the value; the renderer owns that" do
      assert Attribute.attribute(:text, ~s|a < "b" & c|) == {"data-text", ~s|a < "b" & c|}
    end
  end
end
