defmodule DatastarTest do
  use ExUnit.Case, async: true

  doctest Datastar

  test "the root module documents the library" do
    assert {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Datastar)
    assert moduledoc =~ "Datastar"
  end
end
