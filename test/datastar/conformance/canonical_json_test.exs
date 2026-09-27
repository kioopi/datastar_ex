defmodule Datastar.Conformance.CanonicalJSONTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.Conformance.CanonicalJSON

  test "objects encode compact with lexicographically sorted keys, recursively" do
    term = %{"b" => 2, "a" => %{"z" => nil, "y" => [1, "s", true]}}

    assert CanonicalJSON.encode(term) == ~s({"a":{"y":[1,"s",true],"z":null},"b":2})
  end

  # string_keyed/1: decoded-JSON shape of a generated object.
  defp string_keyed(%{} = map),
    do: Map.new(map, fn {k, v} -> {Datastar.Generators.normalize_key(k), string_keyed(v)} end)

  defp string_keyed(list) when is_list(list), do: Enum.map(list, &string_keyed/1)
  defp string_keyed(other), do: other

  property "output decodes back to the original term" do
    check all(object <- Datastar.Generators.json_object()) do
      decoded_shape = string_keyed(object)
      assert JSON.decode!(CanonicalJSON.encode(decoded_shape)) == decoded_shape
    end
  end

  property "output is independent of map construction order and idempotent" do
    check all(object <- Datastar.Generators.json_object()) do
      decoded_shape = string_keyed(object)
      canonical = CanonicalJSON.encode(decoded_shape)

      shuffled = decoded_shape |> Enum.shuffle() |> Map.new()
      assert CanonicalJSON.encode(shuffled) == canonical
      assert canonical |> JSON.decode!() |> CanonicalJSON.encode() == canonical
      assert CanonicalJSON.encode(%{"a" => 1, "b" => [1, 2]}) == ~s({"a":1,"b":[1,2]})
    end
  end

  test "invalid input raises" do
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{atom_key: 1}) end
    assert_raise ArgumentError, fn -> CanonicalJSON.encode({:tuple}) end
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"d" => ~D[2026-09-27]}) end
  end
end
