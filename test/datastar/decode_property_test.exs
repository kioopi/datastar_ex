defmodule Datastar.DecodePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.{Dataline, Decode, Generators}

  # NOT String.trim/2 — that trims an exact string, not a character set.
  defp blank?(text), do: String.replace(text, [" ", "\t", "\f", "\r", "\n"], "") == ""

  # Elements.patch/2 normalizes line endings to LF and trims trailing
  # blank lines, so a round trip can only be equality against the
  # normalized content. Asserting against the original binary would fail
  # for any input with a trailing newline.
  defp normalize(elements) do
    case elements |> Dataline.split() |> Dataline.trim_trailing_blank() do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  # The blank-filter clause is placed directly after `html <- ...`, before the
  # `opts <- ...` clause, not after it. `check all` compiles each filtering
  # clause into the *nearest preceding* generator's bind_filter retry loop:
  # placed after `opts`, a blank `html` would make `opts` retry to its
  # consecutive-failure budget while `html` stays fixed and blank, raising
  # `StreamData.FilterTooNarrowError`. Placed right after `html`, a blank
  # draw reshuffles `html` itself.
  property "element events round-trip to normalized content and normalized options" do
    check all(
            html <- Generators.multiline_text(),
            not blank?(html),
            opts <- Generators.element_opts()
          ) do
      assert {:ok, decoded} = Decode.event(Datastar.patch_elements(html, opts))

      assert decoded.type == :patch_elements
      assert decoded.elements == normalize(html)
      assert decoded.mode == Keyword.get(opts, :mode, :outer)
      assert decoded.namespace == Keyword.get(opts, :namespace, :html)
      assert decoded.use_view_transition == Keyword.get(opts, :use_view_transition, false)
      assert decoded.retry_duration == Keyword.get(opts, :retry_duration, 1_000)
      assert Map.get(decoded, :selector) == Keyword.get(opts, :selector)

      assert Map.get(decoded, :view_transition_selector) ==
               Keyword.get(opts, :view_transition_selector)

      assert Map.get(decoded, :event_id) == Keyword.get(opts, :event_id)
    end
  end

  # Both sides go through a JSON round trip: generated keys may be atoms or
  # integers that normalize to strings, and member order is not a stable
  # API (core spec §3.5).
  property "signal events round-trip to the exact JSON the constructor produced" do
    check all(
            object <- Generators.json_object(),
            only_if_missing <- boolean(),
            retry <- Generators.retry_duration()
          ) do
      event =
        Datastar.patch_signals(object,
          only_if_missing: only_if_missing,
          retry_duration: retry
        )

      assert {:ok, decoded} = Decode.event(event)
      assert decoded.type == :patch_signals
      assert decoded.only_if_missing == only_if_missing
      assert decoded.retry_duration == retry
      assert {:ok, decoded_json} = JSON.decode(decoded.signals)
      assert {:ok, expected} = object |> JSON.encode!() |> JSON.decode()
      assert decoded_json == expected
    end
  end

  property "raw signal JSON travels byte-for-byte" do
    check all(json <- Generators.json_object() |> map(&JSON.encode!/1)) do
      assert {:ok, %{signals: ^json}} = Decode.event(Datastar.patch_signals_raw(json))
    end
  end

  property "removals round-trip with elements: nil" do
    check all(selector <- Generators.selector()) do
      assert {:ok, decoded} = Decode.event(Datastar.remove_elements(selector))

      assert decoded.mode == :remove
      assert decoded.selector == selector
      assert decoded.elements == nil
    end
  end
end
