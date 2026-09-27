defmodule Datastar.Conformance.Dispatcher do
  @moduledoc """
  Translates official-suite event descriptions (SDK core spec §11.3) into
  public core constructor calls. All events are built before any SSE
  output so malformed fixtures can still receive a plain 400 (§9.6).

  Enum strings map through explicit allowlists — never `String.to_atom/1`
  on external input (§15.4). Conformance infrastructure, not public API.
  """

  @modes %{
    "outer" => :outer,
    "inner" => :inner,
    "remove" => :remove,
    "replace" => :replace,
    "prepend" => :prepend,
    "append" => :append,
    "before" => :before,
    "after" => :after
  }

  @namespaces %{"html" => :html, "svg" => :svg, "mathml" => :mathml}

  @spec events(map()) :: {:ok, [Datastar.SSE.event()]} | {:error, String.t()}
  def events(%{"events" => descriptions}) when is_list(descriptions) do
    {:ok, Enum.map(descriptions, &build!/1)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def events(_other), do: {:error, "expected a JSON object with an events array"}

  defp build!(%{"type" => "patchElements"} = desc) do
    opts =
      []
      |> put_string(:selector, desc["selector"])
      |> put_enum(:mode, desc["mode"], @modes)
      |> put_boolean(:use_view_transition, desc["useViewTransition"])
      |> put_string(:view_transition_selector, desc["viewTransitionSelector"])
      |> put_enum(:namespace, desc["namespace"], @namespaces)
      |> put_shared(desc)

    Datastar.Elements.patch(desc["elements"], opts)
  end

  defp build!(%{"type" => "patchSignals"} = desc) do
    raw = desc["signals-raw"] || canonical_signals!(desc["signals"])

    opts =
      []
      |> put_boolean(:only_if_missing, desc["onlyIfMissing"])
      |> put_shared(desc)

    Datastar.Signals.patch_raw(raw, opts)
  end

  defp build!(%{"type" => "executeScript"} = desc) do
    opts =
      []
      |> put_attributes(desc["attributes"])
      |> put_boolean(:auto_remove, desc["autoRemove"])
      |> put_shared(desc)

    Datastar.Script.execute(desc["script"], opts)
  end

  defp build!(%{"type" => other}) do
    raise ArgumentError, "unknown event type: #{inspect(other, limit: 5)}"
  end

  defp build!(_desc), do: raise(ArgumentError, "event description missing a type")

  defp canonical_signals!(nil), do: raise(ArgumentError, "patchSignals requires signals")

  defp canonical_signals!(signals) when is_map(signals),
    do: Datastar.Conformance.CanonicalJSON.encode(signals)

  defp canonical_signals!(signals) do
    raise ArgumentError, "signals must be an object, got: #{inspect(signals, limit: 5)}"
  end

  defp put_shared(opts, desc) do
    opts
    |> put_string(:event_id, desc["eventId"])
    |> put_retry(desc["retryDuration"])
  end

  defp put_string(opts, _key, nil), do: opts
  defp put_string(opts, key, value) when is_binary(value), do: [{key, value} | opts]

  defp put_string(_opts, key, value) do
    raise ArgumentError, "#{inspect(key)} must be a string, got: #{inspect(value, limit: 5)}"
  end

  defp put_boolean(opts, _key, nil), do: opts
  defp put_boolean(opts, key, value) when is_boolean(value), do: [{key, value} | opts]

  defp put_boolean(_opts, key, value) do
    raise ArgumentError, "#{inspect(key)} must be a boolean, got: #{inspect(value, limit: 5)}"
  end

  defp put_enum(opts, _key, nil, _allowed), do: opts

  defp put_enum(opts, key, value, allowed) do
    case allowed do
      %{^value => atom} -> [{key, atom} | opts]
      _other -> raise ArgumentError, "unknown #{inspect(key)}: #{inspect(value, limit: 5)}"
    end
  end

  defp put_retry(opts, nil), do: opts

  defp put_retry(opts, retry) when is_integer(retry) and retry >= 0,
    do: [{:retry_duration, retry} | opts]

  defp put_retry(_opts, retry) do
    raise ArgumentError,
          "retryDuration must be a non-negative integer, got: #{inspect(retry, limit: 5)}"
  end

  defp put_attributes(opts, nil), do: opts
  defp put_attributes(opts, %{} = attributes), do: [{:attributes, attributes} | opts]

  defp put_attributes(_opts, other) do
    raise ArgumentError, "attributes must be an object, got: #{inspect(other, limit: 5)}"
  end
end
