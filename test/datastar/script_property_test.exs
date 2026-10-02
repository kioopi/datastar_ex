defmodule Datastar.ScriptPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.{Elements, Generators, Script}

  defp roundtrip(event) do
    [event |> Datastar.SSE.encode() |> IO.iodata_to_binary()]
    |> ServerSentEvents.decode_stream()
    |> Enum.to_list()
  end

  property "execute equals the documented Elements.patch expansion (§12.10)" do
    check all(
            script <- Generators.script_source(),
            attrs <- Generators.safe_attributes(),
            auto <- boolean()
          ) do
      event = Script.execute(script, auto_remove: auto, attributes: attrs)

      [_selector, _mode | element_lines] = String.split(event.data, "\n")
      html = element_lines |> Enum.map_join("\n", &String.replace_prefix(&1, "elements ", ""))

      assert event == Elements.patch(html, selector: "body", mode: :append)
      assert String.starts_with?(html, "<script")
      assert String.ends_with?(html, "</script>")
    end
  end

  property "auto-removal presence matches the option, attribute order is name-sorted" do
    check all(
            script <- Generators.script_source(),
            attrs <- Generators.safe_attributes(),
            auto <- boolean()
          ) do
      data = Script.execute(script, auto_remove: auto, attributes: attrs).data
      assert data =~ ~s{data-effect="el.remove()"} == auto

      shuffled = attrs |> Enum.shuffle() |> Map.new()
      assert Script.execute(script, auto_remove: auto, attributes: shuffled).data == data
    end
  end

  # The HTML parser folds attribute names to lowercase and keeps only the
  # first of a duplicate pair, so a name that reaches the wire in mixed case
  # can shadow a generated one.
  property "rendered attribute names are lowercase and unique" do
    check all(
            script <- Generators.script_source(),
            attrs <- Generators.safe_attributes(),
            auto <- boolean()
          ) do
      names =
        Script.execute(script, auto_remove: auto, attributes: attrs).data
        |> String.split("\n")
        |> Enum.map_join("\n", &String.replace_prefix(&1, "elements ", ""))
        |> then(&Regex.scan(~r/ ([A-Za-z0-9_:.-]+)="/, &1, capture: :all_but_first))
        |> List.flatten()

      assert names == Enum.map(names, &String.downcase(&1, :ascii))
      assert names == Enum.uniq(names)
    end
  end

  property "no case-insensitive </script survives inside the generated element" do
    check all(script <- Generators.script_source()) do
      data = Script.execute(script, auto_remove: false).data
      inner = data |> String.replace_suffix("</script>", "")
      refute inner =~ ~r{</script}i
    end
  end

  property "attribute values cannot escape their quotes; events round-trip" do
    check all(
            value <- StreamData.string(:utf8, max_length: 20),
            script <- Generators.script_source()
          ) do
      event = Script.execute(script, auto_remove: false, attributes: %{"data-v" => value})

      # Between `data-v="` and the next `"` there is no raw quote, <, or >.
      [_, rest] = String.split(event.data, ~s(data-v="), parts: 2)
      [rendered, _] = String.split(rest, "\"", parts: 2)
      refute String.contains?(rendered, ["\"", "<", ">"])

      assert roundtrip(event) == [event]
    end
  end
end
