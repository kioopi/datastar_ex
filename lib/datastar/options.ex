defmodule Datastar.Options do
  @moduledoc """
  Internal option plumbing shared by the Datastar event constructors and
  the signal reader (SDK core spec §5.2–§5.3).

  Validates keyword options — unknown and duplicate keys are programming
  errors — and applies the shared `:event_id` and `:retry_duration`
  options to a semantic `Datastar.SSE.event()` map. Not public API.
  """

  alias Datastar.Validate

  @typedoc "The `:event_id` and `:retry_duration` options every event constructor accepts (§5.3)."
  @type shared_option :: {:event_id, String.t()} | {:retry_duration, non_neg_integer()}

  @doc """
  Validates that `opts` is a keyword list whose keys are all in `allowed`
  and unique, and returns it with defaults applied. Raises `ArgumentError`
  otherwise.

  `allowed` takes the same shape as `Keyword.validate!/2`: a bare atom
  allows a key, a `{key, default}` pair allows it and supplies a default
  when absent. Unlike `Keyword.validate!/2`, the error names only the
  offending key — option values never reach the message.

  ## Examples

      iex> Datastar.Options.validate!([event_id: "1"], [:event_id])
      [event_id: "1"]

      iex> Datastar.Options.validate!([], [:event_id, status: 200])
      [status: 200]

  """
  @spec validate!(keyword(), [atom() | {atom(), term()}]) :: keyword()
  def validate!(opts, allowed) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "options must be a keyword list, got: #{inspect(opts, limit: 5)}"
    end

    case Keyword.validate(opts, allowed) do
      {:ok, opts} -> opts
      {:error, _invalid} -> raise_invalid_key!(opts, allowed)
    end
  end

  defp raise_invalid_key!(opts, allowed) do
    allowed_keys =
      Enum.map(allowed, fn
        {key, _default} -> key
        key -> key
      end)

    keys = Keyword.keys(opts)

    case Enum.find(keys, &(&1 not in allowed_keys)) do
      nil -> raise ArgumentError, "duplicate option #{inspect(hd(keys -- Enum.uniq(keys)))}"
      key -> raise ArgumentError, "unknown option #{inspect(key)}"
    end
  end

  @doc """
  Fetches the boolean option `key`, raising `ArgumentError` if its value
  is not a boolean.

  `opts` must already have been through `validate!/2` with a default for
  `key`; a missing key raises `KeyError`, which signals a missing default
  rather than a caller error.

  ## Examples

      iex> Datastar.Options.fetch_boolean!([auto_remove: true], :auto_remove)
      true

  """
  @spec fetch_boolean!(keyword(), atom()) :: boolean()
  def fetch_boolean!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a boolean, got: #{inspect(other, limit: 5)}"
    end
  end

  @doc """
  Fetches the positive integer option `key`, raising `ArgumentError` if
  its value is anything else.

  Like `fetch_boolean!/2`, it expects `opts` to have been through
  `validate!/2` with a default for `key`.

  ## Examples

      iex> Datastar.Options.fetch_pos_integer!([max_length: 1_000], :max_length)
      1000

  """
  @spec fetch_pos_integer!(keyword(), atom()) :: pos_integer()
  def fetch_pos_integer!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got: #{inspect(other, limit: 5)}"
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
      {:ok, id} -> Map.put(event, :id, id |> Validate.utf8!() |> Validate.single_line!())
    end
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
