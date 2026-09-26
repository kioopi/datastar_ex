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
end
