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
  @allowed_opts [:only_if_missing, :event_id, :retry_duration]

  @type patch_option ::
          {:only_if_missing, boolean()}
          | {:event_id, String.t()}
          | {:retry_duration, non_neg_integer()}

  @doc """
  Constructs a `datastar-patch-signals` event from a pre-encoded JSON
  binary, transported faithfully: line endings are normalized to LF and
  every logical line becomes one `signals` dataline; nothing is
  compacted, reformatted, or trimmed.

  The binary must be valid, non-empty UTF-8 containing valid JSON — the
  JSON grammar itself is a documented caller precondition (§7.2).
  """
  @spec patch_raw(String.t(), [patch_option()]) :: Datastar.SSE.event()
  def patch_raw(json, opts \\ []) do
    Options.validate_keys!(opts, @allowed_opts)
    only_if_missing? = validate_only_if_missing!(opts)
    validate_json_binary!(json)

    signal_lines = json |> Dataline.split() |> Enum.map(&("signals " <> &1))
    datalines = if only_if_missing?, do: ["onlyIfMissing true" | signal_lines], else: signal_lines

    Options.apply_shared!(%{event: @event_type, data: Enum.join(datalines, "\n")}, opts)
  end

  defp validate_only_if_missing!(opts) do
    case Keyword.get(opts, :only_if_missing, false) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError,
              ":only_if_missing must be a boolean, got: #{inspect(other, limit: 5)}"
    end
  end

  defp validate_json_binary!(json) do
    unless is_binary(json) and String.valid?(json) do
      raise ArgumentError, "signals JSON must be a valid UTF-8 binary"
    end

    if json == "" do
      raise ArgumentError, "signals JSON must not be empty"
    end

    :ok
  end
end
