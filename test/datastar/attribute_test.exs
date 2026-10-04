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

    test "rejects a modifier name containing a dot, which the client reads as an argument" do
      assert_raise ArgumentError, fn ->
        Attribute.attribute("on", "f()", key: "click", modifiers: ["a.b"])
      end

      assert_raise ArgumentError, fn ->
        Attribute.attribute("on", "f()", key: "click", modifiers: [{"a.b", "1"}])
      end
    end

    test "rejects a modifier argument containing a dot, which the client splits in two" do
      assert_raise ArgumentError, fn ->
        Attribute.attribute("on", "f()", key: "click", modifiers: [delay: "1.5s"])
      end
    end

    test "accepts a dot in a key: the client never splits a key on a dot" do
      assert Attribute.attribute("on", "f()", key: "a.b") == {"data-on:a.b", "f()"}
    end

    test "still accepts digit-led modifier arguments" do
      assert {"data-on:click__debounce.500ms__delay.4s", _} =
               Attribute.attribute("on", "f()",
                 key: "click",
                 modifiers: [debounce: "500ms", delay: "4s"]
               )
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

  describe "on/2,3" do
    test "uses the colon, not a hyphen" do
      assert Attribute.on(:click, "@delete('/items/1')") ==
               {"data-on:click", "@delete('/items/1')"}
    end

    test "accepts modifiers as plain options" do
      assert Attribute.on(:init, "el.remove()", delay: "4s") ==
               {"data-on:init__delay.4s", "el.remove()"}
    end

    test "accepts a bare modifier" do
      assert Attribute.on(:click, "f()", [:once]) == {"data-on:click__once", "f()"}
    end

    test "accepts a hyphenated DOM event name" do
      assert Attribute.on("my-event", "f()") == {"data-on:my-event", "f()"}
    end

    test "rejects an event name that would change the parse" do
      assert_raise ArgumentError, fn -> Attribute.on("cl:ick", "f()") end
    end
  end

  describe "bind/1 and text/1" do
    test "bind uses the value form" do
      assert Attribute.bind("text") == {"data-bind", "text"}
      assert Attribute.bind(:fontSize) == {"data-bind", "fontSize"}
    end

    test "text takes an expression" do
      assert Attribute.text("$count") == {"data-text", "$count"}
    end
  end

  describe "action/2,3" do
    test "builds an action expression" do
      assert Attribute.action(:put, "/items/42") == "@put('/items/42')"
    end

    test "accepts every Datastar action verb" do
      assert Attribute.action(:get, "/x") == "@get('/x')"
      assert Attribute.action(:post, "/x") == "@post('/x')"
      assert Attribute.action(:patch, "/x") == "@patch('/x')"
      assert Attribute.action(:delete, "/x") == "@delete('/x')"
    end

    test "a single quote in the URL cannot close the JS string" do
      assert Attribute.action(:put, "/items/it's") == ~S|@put('/items/it\'s')|
    end

    test "a backslash in the URL is escaped" do
      assert Attribute.action(:put, ~S(/a\b)) == ~S|@put('/a\\b')|
    end

    test "a backslash and a quote together are each escaped once" do
      assert Attribute.action(:put, ~S|/a\'b|) == ~S|@put('/a\\\'b')|
    end

    test "composes into on/2" do
      assert Attribute.on(:click, Attribute.action(:put, "/items/42")) ==
               {"data-on:click", "@put('/items/42')"}
    end

    test "rejects an unknown verb" do
      assert_raise ArgumentError, ~r/action verb/, fn ->
        Attribute.action(String.to_existing_atom("fetch"), "/x")
      end
    end

    test "rejects CR, LF and NUL in the URL" do
      for bad <- ["/a\nb", "/a\rb", "/a\0b"] do
        assert_raise ArgumentError, fn -> Attribute.action(:get, bad) end
      end
    end
  end
end
