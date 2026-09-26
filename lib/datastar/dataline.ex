defmodule Datastar.Dataline do
  @moduledoc """
  Internal logical-dataline helpers shared by the Datastar constructors
  (SDK core spec §6.4, §7.3): newline normalization and splitting, and
  trailing-blank-line trimming. Not public API.
  """

  @doc """
  Normalizes CRLF and lone CR to LF and splits into logical lines,
  preserving empty components.

  ## Examples

      iex> Datastar.Dataline.split("a\\r\\nb\\rc\\n")
      ["a", "b", "c", ""]

  """
  @spec split(binary()) :: [binary()]
  # :binary matching is leftmost-longest, so CRLF wins over a lone CR —
  # the same single-pass normalization Datastar.SSE uses.
  def split(binary), do: :binary.split(binary, ["\r\n", "\r", "\n"], [:global])

  @doc """
  Drops trailing lines that are empty or ASCII-whitespace-only (§6.4).
  Interior lines, including blank ones, are preserved.

  ## Examples

      iex> Datastar.Dataline.trim_trailing_blank(["<div>", "", " \\t", ""])
      ["<div>"]

  """
  @spec trim_trailing_blank([binary()]) :: [binary()]
  def trim_trailing_blank(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&ascii_blank?/1)
    |> Enum.reverse()
  end

  # ASCII whitespace that can remain within a line after splitting:
  # space, tab, form feed. Unicode whitespace (NBSP, U+2028, …) is content.
  defp ascii_blank?(<<c, rest::binary>>) when c in [?\s, ?\t, ?\f], do: ascii_blank?(rest)
  defp ascii_blank?(<<>>), do: true
  defp ascii_blank?(_line), do: false
end
