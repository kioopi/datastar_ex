defmodule Datastar.Script do
  @moduledoc """
  Script-execution events (SDK core spec §8): a defined specialization of
  element patching, never a third Datastar event type.

  `execute/2` wraps trusted JavaScript in a `<script>` element and
  delegates to `Datastar.Elements.patch/2` with `selector: "body"` and
  `mode: :append`. By default the element removes itself after running
  (`data-effect="el.remove()"`).

  The script source is trusted executable code — this module escapes the
  attribute context it generates and neutralizes `</script` breakout
  sequences, but it is not a JavaScript sanitizer and does not make
  untrusted code safe.

  ## Examples

      iex> Datastar.Script.execute("console.log('hi')", auto_remove: false)
      %{event: "datastar-patch-elements", data: "selector body\\nmode append\\nelements <script>console.log('hi')</script>"}

  """

  alias Datastar.{Elements, Options}

  @allowed_opts [
    :event_id,
    :retry_duration,
    attributes: %{},
    auto_remove: true
  ]
  @shared_opts [:event_id, :retry_duration]
  @reserved_attribute "data-effect"
  @auto_remove_value "el.remove()"
  @name_format ~r/\A[A-Za-z0-9_:.-]+\z/

  @type attribute_name :: String.t() | atom()
  @type attributes :: %{optional(attribute_name()) => String.t()}

  @type execute_option ::
          {:auto_remove, boolean()}
          | {:attributes, attributes()}
          | {:event_id, String.t()}
          | {:retry_duration, non_neg_integer()}

  @doc """
  Constructs a `datastar-patch-elements` event that executes `script` in
  the browser.

  Attribute names must match `[A-Za-z0-9_:.-]+`; values are escaped for
  the double-quoted HTML attribute context and attributes render sorted
  by name. When `auto_remove` is true (the default), `data-effect` is
  reserved and supplying it raises.
  """
  @spec execute(String.t(), [execute_option()]) :: Datastar.SSE.event()
  def execute(script, opts \\ []) do
    opts = Options.validate!(opts, @allowed_opts)
    validate_script!(script)
    auto_remove? = Options.fetch_boolean!(opts, :auto_remove)

    attributes =
      opts
      |> Keyword.fetch!(:attributes)
      |> normalize_attributes!(auto_remove?)
      |> maybe_put_auto_remove(auto_remove?)
      |> Enum.sort_by(fn {name, _value} -> name end)

    html = "<script" <> render_attributes(attributes) <> ">" <> neutralize(script) <> "</script>"

    Elements.patch(html, [selector: "body", mode: :append] ++ Keyword.take(opts, @shared_opts))
  end

  defp validate_script!(script) do
    unless is_binary(script) and String.valid?(script) do
      raise ArgumentError, "script must be a valid UTF-8 binary"
    end

    :ok
  end

  defp normalize_attributes!(attributes, auto_remove?) when is_non_struct_map(attributes) do
    Enum.reduce(attributes, %{}, fn {name, value}, acc ->
      normalized = normalize_name!(name)

      if auto_remove? and normalized == @reserved_attribute do
        raise ArgumentError,
              "#{@reserved_attribute} is reserved while auto_remove is true"
      end

      if Map.has_key?(acc, normalized) do
        raise ArgumentError, "duplicate attribute name #{inspect(normalized)}"
      end

      Map.put(acc, normalized, validate_value!(normalized, value))
    end)
  end

  defp normalize_attributes!(attributes, _auto_remove?) do
    raise ArgumentError, ":attributes must be a map, got: #{inspect(attributes, limit: 5)}"
  end

  defp normalize_name!(name) when is_atom(name), do: normalize_name!(Atom.to_string(name))

  defp normalize_name!(name) when is_binary(name) do
    unless name =~ @name_format do
      raise ArgumentError, "invalid attribute name: #{inspect(name, limit: 5)}"
    end

    name
  end

  defp normalize_name!(name) do
    raise ArgumentError,
          "attribute names must be binaries or atoms, got: #{inspect(name, limit: 5)}"
  end

  defp validate_value!(name, value) do
    unless is_binary(value) and String.valid?(value) do
      raise ArgumentError, "attribute #{inspect(name)} must have a UTF-8 binary value"
    end

    value
  end

  defp maybe_put_auto_remove(attributes, false), do: attributes

  defp maybe_put_auto_remove(attributes, true) do
    Map.put(attributes, @reserved_attribute, @auto_remove_value)
  end

  defp render_attributes(attributes) do
    Enum.map_join(attributes, "", fn {name, value} ->
      " " <> name <> "=\"" <> escape_attribute(value) <> "\""
    end)
  end

  defp escape_attribute(value), do: String.replace(value, ["&", "\"", "<", ">"], &escape_char/1)

  defp escape_char("&"), do: "&amp;"
  defp escape_char("\""), do: "&quot;"
  defp escape_char("<"), do: "&lt;"
  defp escape_char(">"), do: "&gt;"

  # A case-insensitive `</script` inside the source would terminate the
  # generated element during HTML parsing (§8.4). `<\/script` is
  # equivalent inside JS string and regex literals, where such data lives.
  defp neutralize(script), do: Regex.replace(~r{</(script)}i, script, "<\\\\/\\1")
end
