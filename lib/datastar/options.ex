defmodule Datastar.Options do
  @moduledoc """
  Internal option plumbing shared by the Datastar event constructors and
  the signal reader (SDK core spec §5.2–§5.3).

  Validates keyword options — unknown and duplicate keys are programming
  errors — and applies the shared `:event_id` and `:retry_duration`
  options to a semantic `Datastar.SSE.event()` map. Not public API.
  """

  @doc """
  Validates that `opts` is a keyword list whose keys are all in `allowed`
  and unique. Raises `ArgumentError` otherwise.

  ## Examples

      iex> Datastar.Options.validate_keys!([event_id: "1"], [:event_id])
      :ok

  """
  @spec validate_keys!(keyword(), [atom()]) :: :ok
  def validate_keys!(opts, allowed) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "options must be a keyword list, got: #{inspect(opts, limit: 5)}"
    end

    keys = Keyword.keys(opts)

    case Enum.find(keys, &(&1 not in allowed)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown option #{inspect(key)}"
    end

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _rest] -> raise ArgumentError, "duplicate option #{inspect(key)}"
    end
  end

  @default_retry_duration 1_000

  @doc """
  Applies the shared `:event_id` and `:retry_duration` options (§5.3).

  The id is included whenever explicitly supplied — an empty id resets
  the browser's last event ID. The retry is included only when it
  differs from the Datastar default of `1000` ms; `0` is preserved.

  ## Examples

      iex> Datastar.Options.apply_shared!(%{data: "d"}, event_id: "1", retry_duration: 1_000)
      %{data: "d", id: "1"}

  """
  @spec apply_shared!(map(), keyword()) :: map()
  def apply_shared!(event, opts) do
    event
    |> apply_event_id(opts)
    |> apply_retry(opts)
  end

  defp apply_event_id(event, opts) do
    case Keyword.fetch(opts, :event_id) do
      :error -> event
      {:ok, id} -> Map.put(event, :id, validate_event_id!(id))
    end
  end

  defp validate_event_id!(id) do
    unless is_binary(id) and String.valid?(id) do
      raise ArgumentError, ":event_id must be a valid UTF-8 binary"
    end

    if String.contains?(id, ["\0", "\r", "\n"]) do
      raise ArgumentError, ":event_id must not contain NULL, CR, or LF"
    end

    id
  end

  defp apply_retry(event, opts) do
    case Keyword.fetch(opts, :retry_duration) do
      :error ->
        event

      {:ok, @default_retry_duration} ->
        event

      {:ok, retry} when is_integer(retry) and retry >= 0 ->
        Map.put(event, :retry, retry)

      {:ok, other} ->
        raise ArgumentError,
              ":retry_duration must be a non-negative integer, got: #{inspect(other, limit: 5)}"
    end
  end
end
