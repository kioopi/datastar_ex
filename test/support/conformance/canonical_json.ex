defmodule Datastar.Conformance.CanonicalJSON do
  @moduledoc """
  Deterministic compact JSON for the official conformance adapter (SDK
  core spec §11.3): object members sorted lexicographically by key at
  every depth, scalars/strings/escaping delegated to the standard-library
  `JSON` encoder. Input is decoded JSON, so keys are binaries; anything
  else is a programming error.

  Test-harness compatibility code — not a second general-purpose JSON
  implementation, and not part of the public API.
  """

  @spec encode(term()) :: String.t()
  def encode(object) when is_map(object) and not is_struct(object) do
    inner =
      object
      |> Enum.sort_by(fn {key, _value} -> validate_key!(key) end)
      |> Enum.map_join(",", fn {key, value} -> JSON.encode!(key) <> ":" <> encode(value) end)

    "{" <> inner <> "}"
  end

  def encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  def encode(scalar)
      when is_binary(scalar) or is_number(scalar) or is_boolean(scalar) or is_nil(scalar) do
    JSON.encode!(scalar)
  end

  def encode(other) do
    raise ArgumentError, "not a decoded-JSON term: #{inspect(other, limit: 5)}"
  end

  defp validate_key!(key) when is_binary(key), do: key

  defp validate_key!(key) do
    raise ArgumentError, "decoded-JSON object keys are binaries, got: #{inspect(key, limit: 5)}"
  end
end
