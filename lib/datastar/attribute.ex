defmodule Datastar.Attribute do
  @moduledoc """
  Pure constructors for the Datastar *client* attributes, returned as
  `{name, value}` tuples.

  ## Why this exists

  The client parses an attribute as `data-<plugin>:<key>__<modifiers>`, and
  takes the plugin name as everything up to the colon. `data-on-click` is
  therefore looked up as a plugin named `on-click`, which does not exist, so
  the attribute is **ignored in silence**: no console error, no exception,
  nothing. Written by hand, one typo produces a page that renders perfectly
  and does nothing.

  `attribute/3` validates the plugin name against a list pinned to Datastar
  v1.0.4, so that mistake becomes an `ArgumentError` at the call site instead
  of a silent no-op in the browser. Hyphenated plugin names are real
  (`on-intersect`, `json-signals`), so validation is plain membership in the
  list, never a rule about hyphens.

  Four attributes are not plugins but bare `data-*` attributes
  (`data-ignore`, `data-ignore-morph`, `data-nonce`, `data-preserve-attr`).
  They are accepted too, but never with a `:key`, since there is no plugin to
  key into.

  ## Why tuples and not markup

  A `{name, value}` tuple has one correct rendering in every template engine;
  a string does not. HEEx wants `Phoenix.HTML.Safe`, plain EEx wants raw
  iodata, and another engine wants something else, so rendering is
  deliberately not this module's job. This module is pure: no Plug, no
  Phoenix.

  **The renderer must HTML-escape the value.** HEEx does it automatically; in
  plain EEx, pass the value through your own escaping helper. Nothing here
  pre-escapes for HTML, because a renderer that escapes again would
  double-escape.

  ## Examples

      iex> Datastar.Attribute.attribute("on", "@post('/')", key: "submit")
      {"data-on:submit", "@post('/')"}

      iex> Datastar.Attribute.attribute(:text, "$count")
      {"data-text", "$count"}

  """

  alias Datastar.{Options, Validate}

  # Pinned to Datastar v1.0.4 and verified against the SHA-256-pinned client
  # bundle by Datastar.AttributePluginsTest, which also records how to
  # re-derive both lists from the bundle.
  @plugins ~w(attr bind class computed effect indicator init json-signals on
              on-intersect on-interval on-signal-patch ref show signals style text)

  @bare_attributes ~w(ignore ignore-morph nonce preserve-attr)

  @allowed_opts [:key, modifiers: []]

  # The client parses an attribute as split("__") first, then splits the
  # first segment on its first colon into plugin and key, then splits each
  # modifier segment on "." into a name and its arguments. So:
  #
  #   * a key must not contain "__", or it would be read as modifiers. A "."
  #     or further ":" in a key is inert: the key is everything after the
  #     first colon and is never split again.
  #   * a modifier name or argument must not contain "." (or "__"), or it
  #     would arrive as two parts, e.g. "1.5s" as arguments "1" and "5s".
  #
  # Modifier arguments may start with a digit ("500ms", "4s"); names and
  # keys start with a letter.
  @key_format ~r/\A[A-Za-z][A-Za-z0-9.-]*\z/
  @modifier_name_format ~r/\A[A-Za-z][A-Za-z0-9-]*\z/
  @argument_format ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/

  @typedoc "A modifier: a bare name, or a name with one argument."
  @type modifier :: atom() | String.t() | {atom() | String.t(), String.t()}

  @type option :: {:key, String.t() | atom()} | {:modifiers, [modifier()]}

  @doc """
  The Datastar plugin names `attribute/3` accepts with a `:key`, pinned to
  v1.0.4.

  ## Examples

      iex> "on-intersect" in Datastar.Attribute.plugins()
      true

  """
  @spec plugins() :: [String.t()]
  def plugins, do: @plugins

  @doc """
  The bare `data-*` attributes `attribute/3` accepts without a `:key`, pinned
  to v1.0.4.

  ## Examples

      iex> Datastar.Attribute.bare_attributes()
      ["ignore", "ignore-morph", "nonce", "preserve-attr"]

  """
  @spec bare_attributes() :: [String.t()]
  def bare_attributes, do: @bare_attributes

  @doc """
  Builds a `{name, value}` attribute tuple for `plugin`.

  Options: `:key` (the part after the colon) and `:modifiers` (a list of bare
  names or `{name, argument}` pairs, appended in order after `__`). A `nil`
  value becomes `""`, for attributes whose presence is the whole signal.

  Raises `ArgumentError` for an unknown plugin, a `:key` on a bare attribute,
  a malformed key or modifier, or a value containing CR, LF or NUL, any of
  which would either be ignored by the client or forge an attribute boundary.
  The value is otherwise returned untouched; the renderer escapes it for HTML.

  ## Examples

      iex> Datastar.Attribute.attribute("on", "f()", key: "click", modifiers: [debounce: "500ms"])
      {"data-on:click__debounce.500ms", "f()"}

      iex> Datastar.Attribute.attribute(:ignore, nil)
      {"data-ignore", ""}

  """
  @spec attribute(atom() | String.t(), String.t() | nil, [option()]) :: {String.t(), String.t()}
  def attribute(plugin, value, opts \\ []) do
    opts = Options.validate!(opts, @allowed_opts)
    plugin = plugin |> validate_plugin!() |> check_key!(Keyword.get(opts, :key))

    name =
      "data-" <>
        plugin <>
        key_part(Keyword.get(opts, :key)) <>
        modifier_part(Keyword.fetch!(opts, :modifiers))

    {name, validate_value!(value)}
  end

  defp validate_plugin!(plugin) when is_atom(plugin) and not is_nil(plugin),
    do: validate_plugin!(Atom.to_string(plugin))

  defp validate_plugin!(plugin) when is_binary(plugin) do
    unless plugin in @plugins or plugin in @bare_attributes do
      raise ArgumentError,
            "unknown Datastar plugin #{inspect(plugin)}; " <>
              "the client ignores an unknown plugin in silence. Known plugins: " <>
              Enum.join(@plugins ++ @bare_attributes, ", ")
    end

    plugin
  end

  defp validate_plugin!(other) do
    raise ArgumentError, "plugin must be an atom or binary, got: #{inspect(other, limit: 5)}"
  end

  defp check_key!(plugin, nil), do: plugin

  defp check_key!(plugin, key) do
    if plugin in @bare_attributes do
      raise ArgumentError,
            "#{inspect(plugin)} is a bare attribute, not a plugin, so it cannot take " <>
              "a :key (got #{inspect(key, limit: 5)})"
    end

    plugin
  end

  defp key_part(nil), do: ""
  defp key_part(key) when is_atom(key), do: key_part(Atom.to_string(key))
  defp key_part(key) when is_binary(key), do: ":" <> validate_format!(:key, key, @key_format)

  defp key_part(other) do
    raise ArgumentError, "key must be an atom or binary, got: #{inspect(other, limit: 5)}"
  end

  defp modifier_part(modifiers) when is_list(modifiers) do
    Enum.map_join(modifiers, "", fn
      {name, argument} ->
        "__" <> modifier_name!(name) <> "." <> modifier_argument!(argument)

      name ->
        "__" <> modifier_name!(name)
    end)
  end

  defp modifier_part(other) do
    raise ArgumentError, ":modifiers must be a list, got: #{inspect(other, limit: 5)}"
  end

  defp modifier_name!(name) when is_atom(name), do: modifier_name!(Atom.to_string(name))
  defp modifier_name!(name), do: validate_format!(:modifier, name, @modifier_name_format)

  defp modifier_argument!(argument),
    do: validate_format!(:modifier_argument, argument, @argument_format)

  defp validate_format!(part, value, format) when is_binary(value) do
    unless value =~ format do
      raise ArgumentError,
            "invalid #{part} #{inspect(value, limit: 5)}; " <>
              "must match #{inspect(Regex.source(format))}"
    end

    value
  end

  defp validate_format!(part, other, _format) do
    raise ArgumentError,
          "#{part} must be an atom or binary, got: #{inspect(other, limit: 5)}"
  end

  defp validate_value!(nil), do: ""
  defp validate_value!(value), do: value |> Validate.utf8!() |> Validate.single_line!()
end
