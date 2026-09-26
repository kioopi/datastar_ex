defmodule Datastar.Elements do
  @moduledoc """
  Pure constructors for `datastar-patch-elements` events (SDK core spec §6).

  `patch/2` and `remove/2` validate their input strictly and return a
  semantic `Datastar.SSE.event()` map — they never write SSE framing and
  never send anything. The caller composes them with
  `Datastar.SSE.encode/1` and a transport.

  HTML is transported, not parsed or sanitized: protocol safety (no input
  can forge a dataline) is guaranteed here; whether the HTML itself is
  trustworthy is the application's decision.

  ## Examples

      iex> Datastar.Elements.patch("<li>New</li>", selector: "#feed", mode: :append)
      %{event: "datastar-patch-elements", data: "selector #feed\\nmode append\\nelements <li>New</li>"}

      iex> Datastar.Elements.remove("#obsolete")
      %{event: "datastar-patch-elements", data: "selector #obsolete\\nmode remove"}

  """

  alias Datastar.{Dataline, Options}

  @event_type "datastar-patch-elements"
  @modes [:outer, :inner, :remove, :replace, :prepend, :append, :before, :after]
  @namespaces [:html, :svg, :mathml]
  @allowed_opts [
    :selector,
    :mode,
    :use_view_transition,
    :view_transition_selector,
    :namespace,
    :event_id,
    :retry_duration
  ]

  @typedoc "Element patch mode. The Datastar default is `:outer`."
  @type patch_mode :: :outer | :inner | :remove | :replace | :prepend | :append | :before | :after

  @typedoc "Element namespace. The Datastar default is `:html`."
  @type namespace :: :html | :svg | :mathml

  @type patch_option ::
          {:selector, String.t()}
          | {:mode, patch_mode()}
          | {:use_view_transition, boolean()}
          | {:view_transition_selector, String.t()}
          | {:namespace, namespace()}
          | {:event_id, String.t()}
          | {:retry_duration, non_neg_integer()}

  @doc """
  Constructs a `datastar-patch-elements` event from HTML iodata.

  Line endings are normalized to LF; trailing empty or
  ASCII-whitespace-only lines are trimmed (§6.4); every remaining line
  becomes one `elements` dataline. Elements may be `nil` only for
  selector-based removal (`mode: :remove` with a `:selector`).

  Raises `ArgumentError` on any invalid input; see the SDK core spec §6.6.
  """
  @spec patch(iodata() | nil, [patch_option()]) :: Datastar.SSE.event()
  def patch(elements, opts \\ []) do
    Options.validate_keys!(opts, @allowed_opts)
    validate_option_values!(opts)
    lines = element_lines!(elements)
    validate_presence!(lines, opts)

    datalines = option_datalines(opts) ++ Enum.map(lines, &("elements " <> &1))

    Options.apply_shared!(%{event: @event_type, data: Enum.join(datalines, "\n")}, opts)
  end

  defp element_lines!(nil), do: []

  defp element_lines!(elements) do
    binary =
      try do
        IO.iodata_to_binary(elements)
      rescue
        ArgumentError ->
          reraise ArgumentError.exception(
                    "elements must be valid iodata, got: #{inspect(elements, limit: 5)}"
                  ),
                  __STACKTRACE__
      end

    unless String.valid?(binary) do
      raise ArgumentError, "elements must be valid UTF-8"
    end

    binary |> Dataline.split() |> Dataline.trim_trailing_blank()
  end

  defp validate_presence!([], opts) do
    unless Keyword.get(opts, :mode) == :remove and Keyword.has_key?(opts, :selector) do
      raise ArgumentError,
            "elements are required unless mode: :remove with a non-empty selector"
    end

    :ok
  end

  defp validate_presence!(_lines, _opts), do: :ok

  defp option_datalines(opts) do
    selector = Keyword.get(opts, :selector)
    mode = Keyword.get(opts, :mode, :outer)
    view_transition? = Keyword.get(opts, :use_view_transition, false)
    view_transition_selector = Keyword.get(opts, :view_transition_selector)
    namespace = Keyword.get(opts, :namespace, :html)

    List.flatten([
      if(selector, do: ["selector " <> selector], else: []),
      if(mode == :outer, do: [], else: ["mode " <> Atom.to_string(mode)]),
      if(view_transition?, do: ["useViewTransition true"], else: []),
      if(view_transition_selector,
        do: ["viewTransitionSelector " <> view_transition_selector],
        else: []
      ),
      if(namespace == :html, do: [], else: ["namespace " <> Atom.to_string(namespace)])
    ])
  end

  defp validate_option_values!(opts) do
    Enum.each(opts, fn
      {:selector, value} -> validate_selector!(:selector, value)
      {:view_transition_selector, value} -> validate_selector!(:view_transition_selector, value)
      {:mode, value} -> validate_enum!(:mode, value, @modes)
      {:namespace, value} -> validate_enum!(:namespace, value, @namespaces)
      {:use_view_transition, value} -> validate_boolean!(:use_view_transition, value)
      {_shared, _value} -> :ok
    end)

    if Keyword.has_key?(opts, :view_transition_selector) and
         Keyword.get(opts, :use_view_transition) != true do
      raise ArgumentError, ":view_transition_selector requires use_view_transition: true"
    end

    :ok
  end

  defp validate_selector!(name, value) do
    unless is_binary(value) and String.valid?(value) do
      raise ArgumentError, "#{inspect(name)} must be a valid UTF-8 binary"
    end

    if value == "" do
      raise ArgumentError, "#{inspect(name)} must not be empty"
    end

    if String.contains?(value, ["\r", "\n", "\0"]) do
      raise ArgumentError, "#{inspect(name)} must not contain CR, LF, or NULL"
    end

    :ok
  end

  defp validate_enum!(name, value, allowed) do
    unless value in allowed do
      raise ArgumentError,
            "#{inspect(name)} must be one of #{inspect(allowed)}, got: #{inspect(value, limit: 5)}"
    end

    :ok
  end

  defp validate_boolean!(name, value) do
    unless is_boolean(value) do
      raise ArgumentError, "#{inspect(name)} must be a boolean, got: #{inspect(value, limit: 5)}"
    end

    :ok
  end

  @doc """
  Removes elements matched by `selector` — a strict convenience for
  `patch(nil, selector: selector, mode: :remove)`.

  The `:mode` and `:selector` options are fixed by this function and are
  rejected if supplied.
  """
  @spec remove(String.t(), [patch_option()]) :: Datastar.SSE.event()
  def remove(selector, opts \\ []) do
    for fixed <- [:mode, :selector], Keyword.has_key?(opts, fixed) do
      raise ArgumentError, "remove/2 fixes #{inspect(fixed)}; pass it via patch/2 instead"
    end

    patch(nil, Keyword.merge(opts, selector: selector, mode: :remove))
  end
end
