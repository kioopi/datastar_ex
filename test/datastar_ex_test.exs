defmodule DatastarExTest do
  use ExUnit.Case
  doctest DatastarEx

  test "greets the world" do
    assert DatastarEx.hello() == :world
  end
end
