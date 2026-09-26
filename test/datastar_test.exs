defmodule DatastarTest do
  use ExUnit.Case, async: true

  doctest Datastar

  test "the root module documents the library" do
    assert {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Datastar)
    assert moduledoc =~ "Datastar"
  end

  describe "facade delegation (§4.6)" do
    test "each facade function returns exactly the constructor's event" do
      assert Datastar.patch_elements("<i>x</i>") == Datastar.Elements.patch("<i>x</i>")

      assert Datastar.patch_elements("<i>x</i>", mode: :append) ==
               Datastar.Elements.patch("<i>x</i>", mode: :append)

      assert Datastar.remove_elements("#x") == Datastar.Elements.remove("#x")
      assert Datastar.patch_signals(%{a: 1}) == Datastar.Signals.patch(%{a: 1})

      assert Datastar.patch_signals_raw("{}", only_if_missing: true) ==
               Datastar.Signals.patch_raw("{}", only_if_missing: true)

      assert Datastar.execute_script("f()") == Datastar.Script.execute("f()")
    end
  end
end
