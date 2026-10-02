defmodule Datastar.Validate do
  @moduledoc """
  Internal value checks shared by the Datastar event constructors and
  their option handling. Each check returns its input unchanged, so it
  pipes, or raises `ArgumentError` with a generic message that shows a
  bounded excerpt of the rejected value. Not public API.

  `Datastar.SSE` deliberately keeps its own checks: it depends on no
  other module in this project, so it can move into a package of its own.
  """

  @doc """
  Returns `value` if it is a valid UTF-8 binary; raises `ArgumentError`
  otherwise.

  ## Examples

      iex> Datastar.Validate.utf8!("héllo")
      "héllo"

  """
  @spec utf8!(term()) :: String.t()
  def utf8!(value) do
    unless is_binary(value) and String.valid?(value) do
      raise ArgumentError, "expected a valid UTF-8 binary, got: #{bounded_inspect(value)}"
    end

    value
  end

  @doc """
  Returns `value` if it contains no CR, LF, or NULL — the characters that
  would let a single-line field forge or corrupt SSE datalines; raises
  `ArgumentError` otherwise. Expects a binary (see `utf8!/1`).

  ## Examples

      iex> Datastar.Validate.single_line!("#feed")
      "#feed"

  """
  @spec single_line!(String.t()) :: String.t()
  def single_line!(value) when is_binary(value) do
    if String.contains?(value, ["\r", "\n", "\0"]) do
      raise ArgumentError,
            "expected a single line without CR, LF, or NULL, got: #{bounded_inspect(value)}"
    end

    value
  end

  defp bounded_inspect(value), do: inspect(value, limit: 5, printable_limit: 50)
end
