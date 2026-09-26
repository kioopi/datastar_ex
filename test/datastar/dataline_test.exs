defmodule Datastar.DatalineTest do
  use ExUnit.Case, async: true

  alias Datastar.Dataline

  doctest Datastar.Dataline

  describe "split/1" do
    test "normalizes CRLF and CR to LF and splits, preserving empties" do
      assert Dataline.split("a\nb") == ["a", "b"]
      assert Dataline.split("a\r\nb\rc") == ["a", "b", "c"]
      assert Dataline.split("a\n\nb") == ["a", "", "b"]
      assert Dataline.split("a\n") == ["a", ""]
      assert Dataline.split("") == [""]
    end
  end

  describe "trim_trailing_blank/1" do
    test "drops trailing empty and ASCII-whitespace-only lines" do
      assert Dataline.trim_trailing_blank(["a", ""]) == ["a"]
      assert Dataline.trim_trailing_blank(["a", " \t\f", "", "  "]) == ["a"]
      assert Dataline.trim_trailing_blank([""]) == []
      assert Dataline.trim_trailing_blank(["", " "]) == []
    end

    test "preserves interior blank lines and retained-line whitespace" do
      assert Dataline.trim_trailing_blank(["a", "", "b"]) == ["a", "", "b"]
      assert Dataline.trim_trailing_blank(["a", " ", "b  "]) == ["a", " ", "b  "]
    end

    test "does not treat Unicode whitespace as blank" do
      assert Dataline.trim_trailing_blank(["a", "\u00a0"]) == ["a", "\u00a0"]
      assert Dataline.trim_trailing_blank(["a", "\u2028"]) == ["a", "\u2028"]
    end
  end
end
