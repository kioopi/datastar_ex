defmodule Datastar.ValidateTest do
  use ExUnit.Case, async: true
  doctest Datastar.Validate

  alias Datastar.Validate

  describe "utf8!/1" do
    test "returns a valid UTF-8 binary and rejects anything else" do
      assert Validate.utf8!("héllo") == "héllo"

      for bad <- [<<0xFF>>, :atom, 1, nil, ["iodata"]] do
        assert_raise ArgumentError, ~r/^expected a valid UTF-8 binary, got: /, fn ->
          Validate.utf8!(bad)
        end
      end
    end
  end

  describe "single_line!/1" do
    test "returns a binary without CR, LF, or NULL and rejects one with any of them" do
      assert Validate.single_line!("#feed > li") == "#feed > li"

      for bad <- ["a\rb", "a\nb", "a\r\nb", "a\0b"] do
        assert_raise ArgumentError,
                     ~r/^expected a single line without CR, LF, or NULL, got: /,
                     fn -> Validate.single_line!(bad) end
      end
    end
  end
end
