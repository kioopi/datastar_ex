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

  describe "redirect/2" do
    test "builds the canonical Datastar redirect" do
      assert Datastar.redirect("/").data ==
               ~s{selector body\nmode append\nelements <script data-effect="el.remove()">window.location = "/"</script>}
    end

    test "a single quote in the URL cannot break the JS string" do
      event = Datastar.redirect("/items/it's")

      assert event.data =~ ~s{window.location = "/items/it's"}
      refute event.data =~ ~s{= '/items/it's'}
    end

    test "a double quote in the URL is escaped for the JS string literal" do
      event = Datastar.redirect(~s{/a"b})

      assert event.data =~ ~S{window.location = "/a\"b"}
    end

    test "a backslash in the URL is escaped" do
      assert Datastar.redirect(~S(/a\b)).data =~ ~S{window.location = "/a\\b"}
    end

    test "a newline in the URL cannot forge a dataline" do
      event = Datastar.redirect("/a\nmode inner")

      assert [_selector, _mode, _elements] = String.split(event.data, "\n")
      assert event.data =~ ~S(\n)
    end

    test "</script in the URL is neutralized" do
      assert Datastar.redirect("/a</script>b").data =~ ~S{<\/script>}
    end

    test "passes shared and script options through" do
      event = Datastar.redirect("/", auto_remove: false, event_id: "7")

      assert event.id == "7"
      refute event.data =~ "data-effect"
    end

    test "rejects a non-binary url" do
      assert_raise ArgumentError, fn -> Datastar.redirect(:home) end
    end
  end
end
