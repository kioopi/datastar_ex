defmodule Datastar.SSE.Generators do
  @moduledoc """
  StreamData generators for `Datastar.SSE` property tests: valid events
  weighted toward newline-heavy and empty-string edges, and invalid
  events built around one known violation each.
  """

  import StreamData

  def data do
    multiline =
      bind(list_of(string(:utf8), max_length: 5), fn lines ->
        map(member_of(["\n", "\r", "\r\n"]), &Enum.join(lines, &1))
      end)

    frequency([
      {5, string(:utf8)},
      {2,
       member_of([
         "",
         "\n",
         "\n\n",
         "\r",
         "\r\n",
         "one\n",
         "one\r\ntwo\r",
         " lead",
         ":colon",
         "\0",
         "a\0b"
       ])},
      {3, multiline}
    ])
  end

  # Valid by construction: build from codepoints that exclude CR and LF,
  # rather than filtering broad strings (spec §12.1). ASCII and targeted
  # injection-prone constants are weighted in because uniform Unicode
  # almost never produces colons, spaces, or NULL.
  def event_name do
    frequency([
      {3, string(safe_codepoint_ranges(), max_length: 30)},
      {3, string(:ascii, max_length: 30)},
      {2, member_of(["", " lead", "a:b", ":x", "a\0b", "update"])}
    ])
  end

  def id do
    frequency([
      {3, string(safe_codepoint_ranges(), max_length: 30)},
      {3, string(:ascii, max_length: 30)},
      {2, member_of(["", " lead", "a:b", ":x", "42"])}
    ])
  end

  # All Unicode scalar values except NULL, LF, CR, and surrogates. NULL is
  # legal in :event (added via the constants above) but never in :id.
  defp safe_codepoint_ranges do
    [0x01..0x09, 0x0B..0x0C, 0x0E..0xD7FF, 0xE000..0x10FFFF]
  end

  def retry do
    one_of([non_negative_integer(), integer(0..9_999_999_999_999)])
  end

  def event do
    bind(data(), fn data ->
      %{event: event_name(), id: id(), retry: retry()}
      |> optional_map()
      |> map(&Map.put(&1, :data, data))
    end)
  end

  def comment do
    frequency([
      {5, string(:utf8, max_length: 60)},
      {2, member_of(["", "\n", "x\n", "a\r\nb"])}
    ])
  end

  def invalid_event do
    one_of([
      map(event(), &Map.delete(&1, :data)),
      map(event(), &Map.put(&1, :bogus, 1)),
      map(event(), &Map.put(&1, :data, <<0xFF, 0xFE>>)),
      map(tuple({event(), member_of(["\n", "\r"])}), fn {e, sep} ->
        Map.put(e, :event, "a#{sep}b")
      end),
      map(tuple({event(), member_of(["\0", "\n", "\r"])}), fn {e, sep} ->
        Map.put(e, :id, "a#{sep}b")
      end),
      map(tuple({event(), one_of([negative_integer(), float(), constant("100")])}), fn {e, retry} ->
        Map.put(e, :retry, retry)
      end)
    ])
  end

  defp negative_integer, do: map(positive_integer(), &(-&1))
end
