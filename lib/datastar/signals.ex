defmodule Datastar.Signals do
  @moduledoc """
  Pure constructors for `datastar-patch-signals` events (SDK core spec §7).

  A signal patch carries RFC 7386 JSON Merge Patch semantics: non-null
  values add or replace signals, `null` removes them, nested objects
  patch recursively. This module transports the JSON; it never applies
  the patch.

  `patch/2` takes a JSON-native Elixir map and encodes it with the
  standard-library `JSON` module. `patch_raw/2` takes a pre-encoded JSON
  binary verbatim — its JSON grammar validity is the caller's
  responsibility.

  ## Examples

      iex> Datastar.Signals.patch_raw(~s({"count":2}), only_if_missing: true)
      %{event: "datastar-patch-signals", data: ~s(onlyIfMissing true\\nsignals {"count":2})}

  """

  alias Datastar.{Dataline, Options}

  @event_type "datastar-patch-signals"
  @allowed_opts [:event_id, :retry_duration, only_if_missing: false]

  @type patch_option ::
          {:only_if_missing, boolean()}
          | {:event_id, String.t()}
          | {:retry_duration, non_neg_integer()}

  @typedoc "JSON object member name sources; all normalize to strings."
  @type json_key :: String.t() | atom() | integer()
  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | json_object()
  @type json_object :: %{optional(json_key()) => json_value()}

  @doc """
  Constructs a `datastar-patch-signals` event from a JSON-native Elixir
  map, encoding it with the standard-library `JSON` module.

  Keys may be binaries, atoms, or integers and are normalized to their
  JSON member names; two keys normalizing to the same name are rejected.
  Values may be binaries, numbers, booleans, `nil`, proper lists, and
  non-struct maps — recursively. Structs, tuples, arbitrary atoms, and
  other terms are rejected with `ArgumentError` (§7.1, §7.6). After
  validation, an unexpected `JSON.encode!/1` exception propagates
  unchanged.

  Callers needing exact JSON text or member order use `patch_raw/2`;
  member order chosen by the encoder is not a stable API (§3.5).

  ## Examples

      iex> Datastar.Signals.patch(%{count: 2})
      %{event: "datastar-patch-signals", data: ~s(signals {"count":2})}

  """
  @spec patch(json_object(), [patch_option()]) :: Datastar.SSE.event()
  def patch(signals, opts \\ [])

  def patch(signals, opts) when is_map(signals) and not is_struct(signals) do
    signals
    |> normalize_object!()
    |> JSON.encode!()
    |> patch_raw(opts)
  end

  def patch(other, _opts) do
    raise ArgumentError,
          "signals must be a non-struct map, got: #{inspect(other, limit: 5)}"
  end

  defp normalize_object!(object) do
    Enum.reduce(object, %{}, fn {key, value}, acc ->
      name = normalize_key!(key)

      if Map.has_key?(acc, name) do
        raise ArgumentError,
              "duplicate JSON member name #{inspect(name)} after key normalization"
      end

      Map.put(acc, name, normalize_value!(value))
    end)
  end

  defp normalize_key!(key) when is_binary(key) do
    unless String.valid?(key) do
      raise ArgumentError, "map keys must be valid UTF-8, got: #{inspect(key, limit: 5)}"
    end

    key
  end

  defp normalize_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key!(key) when is_integer(key), do: Integer.to_string(key)

  defp normalize_key!(key) do
    raise ArgumentError,
          "map keys must be binaries, atoms, or integers, got: #{inspect(key, limit: 5)}"
  end

  defp normalize_value!(value) when is_binary(value) do
    unless String.valid?(value) do
      raise ArgumentError, "binary values must be valid UTF-8, got: #{inspect(value, limit: 5)}"
    end

    value
  end

  defp normalize_value!(value) when is_number(value) or is_boolean(value) or is_nil(value) do
    value
  end

  defp normalize_value!(value) when is_map(value) and not is_struct(value) do
    normalize_object!(value)
  end

  defp normalize_value!(value) when is_list(value), do: normalize_list!(value, value)

  defp normalize_value!(value) do
    raise ArgumentError,
          "unsupported JSON value: #{inspect(value, limit: 5)} " <>
            "(supported: binaries, numbers, booleans, nil, proper lists, non-struct maps)"
  end

  defp normalize_list!([], _original), do: []

  defp normalize_list!([head | tail], original) when is_list(tail) do
    [normalize_value!(head) | normalize_list!(tail, original)]
  end

  defp normalize_list!(_improper, original) do
    raise ArgumentError, "lists must be proper lists, got: #{inspect(original, limit: 5)}"
  end

  @doc """
  Constructs a `datastar-patch-signals` event from a pre-encoded JSON
  binary, transported faithfully: line endings are normalized to LF and
  every logical line becomes one `signals` dataline; nothing is
  compacted, reformatted, or trimmed.

  The binary must be valid, non-empty UTF-8 containing valid JSON — the
  JSON grammar itself is a documented caller precondition (§7.2).
  """
  @spec patch_raw(String.t(), [patch_option()]) :: Datastar.SSE.event()
  def patch_raw(json, opts \\ [])

  def patch_raw("", _opts) do
    raise ArgumentError, "signals JSON must not be empty"
  end

  def patch_raw(json, opts) when is_binary(json) do
    unless String.valid?(json) do
      raise ArgumentError, "signals JSON must be a valid UTF-8 binary"
    end

    opts = Options.validate!(opts, @allowed_opts)
    only_if_missing? = Options.fetch_boolean!(opts, :only_if_missing)

    signal_lines = json |> Dataline.split() |> Enum.map(&("signals " <> &1))
    datalines = if only_if_missing?, do: ["onlyIfMissing true" | signal_lines], else: signal_lines

    Options.apply_shared!(%{event: @event_type, data: Enum.join(datalines, "\n")}, opts)
  end

  def patch_raw(_json, _opts) do
    raise ArgumentError, "signals JSON must be a valid UTF-8 binary"
  end
end
