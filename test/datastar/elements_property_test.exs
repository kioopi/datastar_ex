defmodule Datastar.ElementsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.{Elements, Generators}

  defp roundtrip(event) do
    [event |> Datastar.SSE.encode() |> IO.iodata_to_binary()]
    |> ServerSentEvents.decode_stream()
    |> Enum.to_list()
  end

  defp data_lines(event), do: String.split(event.data, "\n")

  # NOT String.trim/2 — that trims an exact string, not a character set.
  defp blank?(text), do: String.replace(text, [" ", "\t", "\f", "\r", "\n"], "") == ""

  # The blank-filter clause is placed directly after `html <- ...`, before the
  # `opts <- ...` clause, not after it. `check all` compiles each filtering
  # clause into the *nearest preceding* generator's bind_filter retry loop
  # (ex_unit_properties.ex): placed after `opts`, a blank `html` would make
  # `opts` retry up to its consecutive-failure budget while `html` stays
  # fixed and still blank — a guaranteed, unrelated-to-`opts` failure that
  # raises `StreamData.FilterTooNarrowError` on the first blank draw. Placed
  # right after `html`, a blank draw instead reshuffles `html` itself.
  property "valid patches are deterministic, typed, and canonical" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html),
            opts <- Generators.element_opts()
          ) do
      event = Elements.patch(html, opts)

      assert event == Elements.patch(html, opts)
      assert event.event == "datastar-patch-elements"
      assert Map.keys(event) -- [:event, :data, :id, :retry] == []
    end
  end

  property "every normalized HTML line appears exactly once, prefixed, in order" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html)
          ) do
      normalized =
        html
        |> String.replace(["\r\n", "\r"], "\n")
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.drop_while(&blank?/1)
        |> Enum.reverse()

      element_lines =
        Elements.patch(html)
        |> data_lines()
        |> Enum.filter(&String.starts_with?(&1, "elements "))
        |> Enum.map(&String.replace_prefix(&1, "elements ", ""))

      assert element_lines == normalized
    end
  end

  property "explicitly supplied defaults equal omission" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html)
          ) do
      assert Elements.patch(html,
               mode: :outer,
               namespace: :html,
               use_view_transition: false,
               retry_duration: 1_000
             ) == Elements.patch(html)
    end
  end

  property "encoding round-trips through the independent SSE decoder" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html),
            opts <- Generators.element_opts()
          ) do
      event = Elements.patch(html, opts)
      assert roundtrip(event) == [event]
      refute event |> Datastar.SSE.encode() |> IO.iodata_to_binary() |> String.contains?("\r")
    end
  end

  # See the note on the first property: the blank-filter clause must come
  # directly after `html <- ...`, before `suffix <- ...`, or a blank draw of
  # `html` exhausts `suffix`'s retry budget instead of reshuffling `html`.
  property "trailing-blank-line trimming is idempotent under appended newlines" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html),
            suffix <- member_of(["\n", "\r\n", "\n \t\n", "\r"])
          ) do
      assert Elements.patch(html <> suffix) == Elements.patch(html)
    end
  end

  property "removal never contains an elements dataline" do
    check all(sel <- Generators.selector()) do
      refute Elements.remove(sel)
             |> data_lines()
             |> Enum.any?(&String.starts_with?(&1, "elements"))
    end
  end

  property "selectors with injected line endings always raise without partial output (§12.9)" do
    check all(
            sel <- Generators.selector(),
            evil <- member_of(["\n", "\r", "\0", "\nelements <b>", "\rdata: x"]),
            position <- member_of([:prefix, :suffix])
          ) do
      bad = if position == :prefix, do: evil <> sel, else: sel <> evil

      assert_raise ArgumentError, fn -> Elements.patch("<i>x</i>", selector: bad) end
    end
  end
end
