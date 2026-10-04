defmodule Datastar.Generators do
  @moduledoc """
  StreamData generators for the Datastar constructor property tests
  (SDK core spec §12.5): valid values by construction, weighted toward
  newline-heavy, empty, and markup-shaped edges.
  """

  import StreamData

  def patch_mode,
    do: member_of([:outer, :inner, :remove, :replace, :prepend, :append, :before, :after])

  def namespace, do: member_of([:html, :svg, :mathml])

  def retry_duration, do: integer(0..100_000)

  def event_id do
    string(:utf8, max_length: 20)
    |> filter(&(not String.contains?(&1, ["\0", "\r", "\n"])))
  end

  @doc "Single-line, non-empty selector strings without CR/LF/NUL."
  def selector do
    frequency([
      {4, string(:alphanumeric, min_length: 1, max_length: 12) |> map(&("#" <> &1))},
      {2, member_of(["#feed", "main > .item", "[data-x=\"1\"]", "#a, #b", "  #pad  ", "é🎉"])},
      {2,
       string(:utf8, min_length: 1, max_length: 20)
       |> filter(&(not String.contains?(&1, ["\0", "\r", "\n"])))}
    ])
  end

  @doc "Multiline text weighted with markup, blank lines, and every line-ending style."
  def multiline_text do
    line =
      frequency([
        {4, string(:utf8, max_length: 15) |> filter(&(not String.contains?(&1, ["\r", "\n"])))},
        {3, member_of(["<div>", "  <span>x</span>", "</div>", "", "  ", "a & b < c", ":colon"])}
      ])

    bind(list_of(line, min_length: 1, max_length: 6), fn lines ->
      map(member_of(["\n", "\r", "\r\n"]), &Enum.join(lines, &1))
    end)
  end

  @doc "Valid element option lists; mode :remove always carries a selector."
  def element_opts do
    optional = fn key, gen -> one_of([constant([]), map(gen, &[{key, &1}])]) end

    [
      optional.(:selector, selector()),
      optional.(:mode, patch_mode() |> filter(&(&1 != :remove))),
      one_of([
        constant([]),
        map(selector(), &[use_view_transition: true, view_transition_selector: &1]),
        constant(use_view_transition: true)
      ]),
      optional.(:namespace, namespace()),
      optional.(:event_id, event_id()),
      optional.(:retry_duration, retry_duration())
    ]
    |> fixed_list()
    |> map(&List.flatten/1)
  end

  @doc "JSON-native objects per spec §7.1, three levels deep at most."
  def json_object, do: json_object(2)

  defp json_object(depth) do
    map_of(json_key(), json_value(depth), max_length: 4)
    |> filter(&unique_normalized_keys?/1)
  end

  defp json_key do
    one_of([
      string(:utf8, min_length: 1, max_length: 8),
      map(string(:alphanumeric, min_length: 1, max_length: 8), &String.to_atom/1),
      integer(0..99)
    ])
  end

  defp json_value(0), do: json_scalar()

  defp json_value(depth) do
    frequency([
      {6, json_scalar()},
      {2, list_of(json_value(depth - 1), max_length: 3)},
      {2, json_object(depth - 1)}
    ])
  end

  defp json_scalar do
    one_of([
      string(:utf8, max_length: 10),
      integer(),
      float(min: -1.0e6, max: 1.0e6),
      boolean(),
      constant(nil)
    ])
  end

  defp unique_normalized_keys?(map) do
    names = Enum.map(Map.keys(map), &normalize_key/1)
    length(names) == length(Enum.uniq(names)) and Enum.all?(Map.values(map), &values_unique?/1)
  end

  defp values_unique?(%{} = map), do: unique_normalized_keys?(map)
  defp values_unique?(list) when is_list(list), do: Enum.all?(list, &values_unique?/1)
  defp values_unique?(_scalar), do: true

  @doc "Normalizes a JSON-native map/list key or scalar to its JSON member name."
  def normalize_key(k) when is_binary(k), do: k
  def normalize_key(k) when is_atom(k), do: Atom.to_string(k)
  def normalize_key(k) when is_integer(k), do: Integer.to_string(k)

  @doc "Script sources weighted with quotes, tags, newlines, and breakout shapes."
  def script_source do
    frequency([
      {4, string(:utf8, max_length: 30)},
      {2,
       member_of([
         "console.log('</script>')",
         "if (a </SCRIPT> b) {}",
         "let s = \"</ScRiPt\";",
         "a();\nb();\n",
         ""
       ])}
    ])
  end

  @doc """
  Safe attribute maps with valid names and plain binary values.

  `name` is the generator names are drawn from. The default is mixed case on
  purpose: HTML attribute names are ASCII case-insensitive, so a lowercase-only
  generator cannot see a case-folding bug. Tests pass a deliberately narrow one
  to force collisions.
  """
  def safe_attributes(
        name \\ string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_], min_length: 1, max_length: 10)
      ) do
    value = string(:utf8, max_length: 15)

    map_of(name, value, max_length: 3)
    |> map(&reject_reserved/1)
    |> filter(&unique_folded_names?/1)
  end

  # Map keys are unique as binaries, so "J" and "j" can both be drawn, but
  # Script.execute/2 downcases attribute names and rejects duplicates. Filtering
  # after reject_reserved/1 is cheaper: that step only removes entries, so it
  # can only remove collisions, and fewer draws are discarded.
  defp unique_folded_names?(attributes) do
    names = Enum.map(Map.keys(attributes), &String.downcase(&1, :ascii))
    length(names) == length(Enum.uniq(names))
  end

  defp reject_reserved(attributes) do
    Map.reject(attributes, fn {name, _value} ->
      String.downcase(name, :ascii) == "data-effect"
    end)
  end
end
