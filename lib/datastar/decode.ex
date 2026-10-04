defmodule Datastar.Decode do
  @moduledoc """
  Reads a Datastar event back out of a parsed SSE event — the inverse of
  the constructors in `Datastar.Elements`, `Datastar.Signals` and
  `Datastar.Script`.

  This module owns the *logical dataline* layer only. It takes an
  already-parsed `t:Datastar.SSE.event/0` and never touches physical SSE
  framing, so it composes with any SSE parser: the `server_sent_events`
  package, a Req or Finch stream, or a hand-rolled one. That split
  mirrors the outbound path, where a constructor builds datalines and
  `Datastar.SSE.encode/1` frames them.

  ## Not an ADR function

  The Datastar SDK ADR specifies event *generation* and reading incoming
  signals; it does not specify decoding events. This function exists for
  consumer tests — so an application can assert on
  `%{type: :patch_elements, selector: "#app"}` instead of matching
  substrings of a wire format it did not serialize. It carries no
  conformance weight.

  ## Decoding is normalized, not literal

  The constructors omit every option equal to its Datastar default, so
  `patch(html)` and `patch(html, mode: :outer)` produce identical events
  and cannot be told apart afterwards. Decoding therefore always
  reinstates defaults. `Datastar.Elements.patch/2` also normalizes line
  endings and trims trailing blank lines, so decoded `:elements` is the
  *normalized* content, not the original binary.

  `:event_id` is the exception that stays optional: an absent `id` field
  and an `id` field present-but-empty are different on the wire, and the
  empty one resets the browser's last event ID (§5.2).

  ## Scripts do not round-trip

  `Datastar.Script.execute/2` is a defined specialization of element
  patching, not a third event type, so a script event decodes as
  `:patch_elements` with the `<script>` element intact in `:elements`.
  Recovering the original source would mean parsing HTML, which this
  module does not do.

  ## Signals stay raw

  `:signals` is the raw JSON binary as it travelled, not a decoded map.
  `Datastar.Signals.Reader.decode/1,2` already owns JSON-object decoding
  and its `:decoder` option, so it composes rather than being duplicated:

      iex> {:ok, %{signals: json}} = Datastar.Decode.event(Datastar.patch_signals(%{"a" => 1}))
      iex> Datastar.Signals.Reader.decode(json)
      {:ok, %{"a" => 1}}

  ## Examples

      iex> Datastar.patch_elements("<p>x</p>", selector: "#t") |> Datastar.Decode.event()
      {:ok, %{type: :patch_elements, mode: :outer, namespace: :html,
              use_view_transition: false, retry_duration: 1000,
              selector: "#t", elements: "<p>x</p>"}}

  """

  @element_event "datastar-patch-elements"
  @signal_event "datastar-patch-signals"
  @default_event "message"
  @default_retry_duration 1_000

  @element_keys %{
    "selector" => :selector,
    "mode" => :mode,
    "useViewTransition" => :use_view_transition,
    "viewTransitionSelector" => :view_transition_selector,
    "namespace" => :namespace
  }

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

  @typedoc "A decoded Datastar event. Defaults are always present; `:event_id` is not."
  @type decoded ::
          %{
            required(:type) => :patch_elements,
            required(:mode) => Datastar.Elements.patch_mode(),
            required(:namespace) => Datastar.Elements.namespace(),
            required(:use_view_transition) => boolean(),
            required(:retry_duration) => non_neg_integer(),
            required(:elements) => String.t() | nil,
            optional(:selector) => String.t(),
            optional(:view_transition_selector) => String.t(),
            optional(:event_id) => String.t()
          }
          | %{
              required(:type) => :patch_signals,
              required(:signals) => String.t(),
              required(:only_if_missing) => boolean(),
              required(:retry_duration) => non_neg_integer(),
              optional(:event_id) => String.t()
            }

  @typedoc "Stable categories for a wire event this module cannot interpret."
  @type decode_error ::
          {:unknown_event, String.t()}
          | {:unknown_dataline, String.t()}
          | {:invalid_value, String.t(), String.t()}
          | {:duplicate_dataline, String.t()}
          | :invalid_dataline
          | :missing_elements
          | :missing_signals

  @doc """
  Decodes one parsed SSE event into its semantic Datastar event.

  Returns `{:error, reason}` for wire data this module cannot interpret —
  untrusted input is data, not a programming error, which follows
  `Datastar.Signals.Reader.decode/1,2` (§9.1). Input that is not a semantic
  SSE event map at all *is* a programming error and raises
  `ArgumentError`.

  Option combinations are not re-validated: this is the inverse of the
  wire format, not a validator of foreign servers, and the constructors
  already guarantee valid combinations outbound.

  ## Examples

      iex> Datastar.remove_elements("#gone") |> Datastar.Decode.event()
      {:ok, %{type: :patch_elements, mode: :remove, namespace: :html,
              use_view_transition: false, retry_duration: 1000,
              selector: "#gone", elements: nil}}

      iex> Datastar.Decode.event(%{event: "chat", data: "hi"})
      {:error, {:unknown_event, "chat"}}

  """
  @spec event(Datastar.SSE.event()) :: {:ok, decoded()} | {:error, decode_error()}
  def event(event) when is_non_struct_map(event) do
    data = fetch_data!(event)

    with {:ok, type} <- event_type(event),
         {:ok, pairs} <- datalines(data),
         {:ok, decoded} <- decode(type, pairs) do
      {:ok, Map.merge(decoded, shared(event))}
    end
  end

  def event(other) do
    raise ArgumentError,
          "expected a semantic SSE event map, got: #{inspect(other, limit: 5)}"
  end

  defp fetch_data!(event) do
    case Map.fetch(event, :data) do
      {:ok, data} when is_binary(data) ->
        data

      _missing_or_wrong ->
        raise ArgumentError,
              "event must carry a binary :data, got: #{inspect(event, limit: 5)}"
    end
  end

  defp event_type(event) do
    case Map.get(event, :event, @default_event) do
      @element_event -> {:ok, :patch_elements}
      @signal_event -> {:ok, :patch_signals}
      other -> {:error, {:unknown_event, other}}
    end
  end

  # One logical dataline per line, each split on its FIRST space. A line
  # with no space cannot be a dataline.
  defp datalines(data) do
    data
    |> String.split("\n")
    |> Enum.reduce_while([], fn line, acc ->
      case String.split(line, " ", parts: 2) do
        [key, value] -> {:cont, [{key, value} | acc]}
        [_no_space] -> {:halt, {:error, :invalid_dataline}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      pairs -> {:ok, Enum.reverse(pairs)}
    end
  end

  defp decode(:patch_elements, pairs) do
    pairs
    |> Enum.reduce_while({%{}, []}, &element_dataline/2)
    |> finish_elements()
  end

  defp decode(:patch_signals, pairs) do
    pairs
    |> Enum.reduce_while({%{}, []}, &signal_dataline/2)
    |> finish_signals()
  end

  defp signal_dataline({"signals", value}, {acc, lines}) do
    {:cont, {acc, [value | lines]}}
  end

  defp signal_dataline({"onlyIfMissing" = key, value}, {acc, lines}) do
    with :ok <- refute_duplicate(acc, :only_if_missing, key),
         {:ok, decoded} <- lookup(%{"true" => true, "false" => false}, key, value) do
      {:cont, {Map.put(acc, :only_if_missing, decoded), lines}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp signal_dataline({key, _value}, _state) do
    {:halt, {:error, {:unknown_dataline, key}}}
  end

  defp finish_signals({:error, reason}), do: {:error, reason}

  defp finish_signals({acc, lines}) do
    case join_content(lines) do
      nil ->
        {:error, :missing_signals}

      signals ->
        {:ok,
         acc
         |> Map.put(:type, :patch_signals)
         |> Map.put(:signals, signals)
         |> Map.put_new(:only_if_missing, false)}
    end
  end

  defp element_dataline({"elements", value}, {acc, lines}) do
    {:cont, {acc, [value | lines]}}
  end

  defp element_dataline({key, value}, {acc, lines}) do
    with {:ok, field} <- element_field(key),
         :ok <- refute_duplicate(acc, field, key),
         {:ok, decoded} <- element_value(field, key, value) do
      {:cont, {Map.put(acc, field, decoded), lines}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp element_field(key) do
    case Map.fetch(@element_keys, key) do
      {:ok, field} -> {:ok, field}
      :error -> {:error, {:unknown_dataline, key}}
    end
  end

  defp refute_duplicate(acc, field, key) do
    if Map.has_key?(acc, field), do: {:error, {:duplicate_dataline, key}}, else: :ok
  end

  defp element_value(:mode, key, value), do: lookup(@modes, key, value)
  defp element_value(:namespace, key, value), do: lookup(@namespaces, key, value)

  defp element_value(:use_view_transition, key, value) do
    lookup(%{"true" => true, "false" => false}, key, value)
  end

  defp element_value(_field, _key, value), do: {:ok, value}

  defp lookup(table, key, value) do
    case Map.fetch(table, value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_value, key, value}}
    end
  end

  defp finish_elements({:error, reason}), do: {:error, reason}

  defp finish_elements({acc, lines}) do
    elements = join_content(lines)
    mode = Map.get(acc, :mode, :outer)

    if is_nil(elements) and not (mode == :remove and Map.has_key?(acc, :selector)) do
      {:error, :missing_elements}
    else
      {:ok,
       acc
       |> Map.put(:type, :patch_elements)
       |> Map.put(:mode, mode)
       |> Map.put(:namespace, Map.get(acc, :namespace, :html))
       |> Map.put(:use_view_transition, Map.get(acc, :use_view_transition, false))
       |> Map.put(:elements, elements)}
    end
  end

  defp join_content([]), do: nil
  defp join_content(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  # An absent `retry` means the client uses the Datastar default, so that
  # is what it decodes to. An absent `id` is genuinely absent: `id: ""`
  # resets the browser's last event ID and must stay distinguishable.
  defp shared(event) do
    base = %{retry_duration: Map.get(event, :retry, @default_retry_duration)}

    case Map.fetch(event, :id) do
      {:ok, id} -> Map.put(base, :event_id, id)
      :error -> base
    end
  end
end
