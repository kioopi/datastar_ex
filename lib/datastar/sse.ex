defmodule Datastar.SSE do
  @moduledoc """
  Canonical Server-Sent Events (`text/event-stream`) encoder.

  Accepts a semantic SSE event map and serializes it into one canonical
  UTF-8 wire representation: LF line endings, lowercase field names, one
  space after each colon, fields ordered `event`, `id`, `retry`, `data`,
  and exactly one terminating blank line.

  ## Examples

      iex> Datastar.SSE.encode(%{data: "hello"}) |> IO.iodata_to_binary()
      "data: hello\\n\\n"

  """

  @typedoc "A semantic SSE event. `:data` is required; other fields are optional."
  @type event :: %{
          required(:data) => String.t(),
          optional(:event) => String.t(),
          optional(:id) => String.t(),
          optional(:retry) => non_neg_integer()
        }

  @doc """
  Validates and canonically serializes one semantic event to iodata.

  Raises `ArgumentError` for input that cannot be encoded faithfully.

  ## Examples

      iex> Datastar.SSE.encode(%{event: "update", id: "42", retry: 2000, data: "a\\nb"})
      ...> |> IO.iodata_to_binary()
      "event: update\\nid: 42\\nretry: 2000\\ndata: a\\ndata: b\\n\\n"

  """
  @spec encode(event()) :: iodata()
  def encode(%{data: data} = event) do
    [
      optional_line(event, :event),
      optional_line(event, :id),
      retry_line(event),
      data_lines(data),
      "\n"
    ]
  end

  defp optional_line(event, key) do
    case event do
      %{^key => value} -> [Atom.to_string(key), ": ", value, "\n"]
      _ -> []
    end
  end

  defp retry_line(%{retry: retry}), do: ["retry: ", Integer.to_string(retry), "\n"]
  defp retry_line(_event), do: []

  defp data_lines(data) do
    data
    |> String.split("\n", trim: false)
    |> Enum.map(&["data: ", &1, "\n"])
  end
end
