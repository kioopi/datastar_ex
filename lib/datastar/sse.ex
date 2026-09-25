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
  def encode(event) do
    validate!(event)

    [
      optional_line(event, :event),
      optional_line(event, :id),
      retry_line(event),
      data_lines(event.data),
      "\n"
    ]
  end

  @known_keys [:data, :event, :id, :retry]

  defp validate!(event) when is_map(event) do
    validate_keys!(event)
    validate_data!(event)
    validate_event_name!(event)
    validate_id!(event)
    validate_retry!(event)
  end

  defp validate!(other) do
    raise ArgumentError,
          "invalid SSE event: expected a map, got: #{inspect(other)}"
  end

  defp validate_keys!(event) do
    unless Map.has_key?(event, :data) do
      raise ArgumentError, "invalid SSE event: missing required :data"
    end

    case Map.keys(event) -- @known_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "invalid SSE event: unknown key #{inspect(hd(unknown))}"
    end
  end

  defp validate_data!(%{data: data}) do
    validate_utf8!(data, ":data")
  end

  defp validate_event_name!(%{event: value}) do
    validate_utf8!(value, ":event")

    if String.contains?(value, ["\r", "\n"]) do
      raise ArgumentError, "invalid SSE event: :event must not contain CR or LF"
    end
  end

  defp validate_event_name!(_event), do: :ok

  defp validate_id!(%{id: value}) do
    validate_utf8!(value, ":id")

    if String.contains?(value, ["\0", "\r", "\n"]) do
      raise ArgumentError, "invalid SSE event: :id must not contain NULL, CR, or LF"
    end
  end

  defp validate_id!(_event), do: :ok

  defp validate_retry!(%{retry: retry}) when is_integer(retry) and retry >= 0, do: :ok

  defp validate_retry!(%{retry: _retry}) do
    raise ArgumentError, "invalid SSE event: :retry must be a non-negative integer"
  end

  defp validate_retry!(_event), do: :ok

  defp validate_utf8!(value, field) do
    unless is_binary(value) and String.valid?(value) do
      raise ArgumentError, "invalid SSE event: #{field} must be a valid UTF-8 binary"
    end
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
    |> normalize_newlines()
    |> String.split("\n", trim: false)
    |> Enum.map(&["data: ", &1, "\n"])
  end

  # CRLF first, then lone CR; :binary matching is leftmost-longest, so a
  # single pass with both patterns is order-correct.
  defp normalize_newlines(binary), do: String.replace(binary, ["\r\n", "\r"], "\n")
end
