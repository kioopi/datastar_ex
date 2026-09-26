defmodule Datastar.SignalsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.{Generators, Signals}

  defp roundtrip(event) do
    [event |> Datastar.SSE.encode() |> IO.iodata_to_binary()]
    |> ServerSentEvents.decode_stream()
    |> Enum.to_list()
  end

  defp reconstruct_json(event) do
    event.data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "signals "))
    |> Enum.map_join("\n", &String.replace_prefix(&1, "signals ", ""))
  end

  property "patch/2 equals patch_raw of the normalized encoding (§12.10)" do
    check all(
            object <- Generators.json_object(),
            only <- boolean()
          ) do
      event = Signals.patch(object, only_if_missing: only)

      assert event.event == "datastar-patch-signals"
      assert String.starts_with?(event.data, "onlyIfMissing true\n") == only

      reconstructed = reconstruct_json(event)
      assert {:ok, decoded} = JSON.decode(reconstructed)
      assert decoded == string_keyed(object)
    end
  end

  property "raw multiline JSON text: every line prefixed exactly once, round-trips" do
    check all(
            lines <-
              list_of(
                string(:utf8, max_length: 12)
                |> filter(&(not String.contains?(&1, ["\r", "\n"]))),
                min_length: 1,
                max_length: 5
              ),
            ending <- member_of(["\n", "\r", "\r\n"])
          ) do
      raw = Enum.join(lines, ending)
      raw = if raw == "", do: "{}", else: raw

      event = Signals.patch_raw(raw)
      data_lines = String.split(event.data, "\n")

      assert Enum.all?(data_lines, &String.starts_with?(&1, "signals "))
      assert length(data_lines) == length(String.split(raw, ["\r\n", "\r", "\n"]))
      assert roundtrip(event) == [event]
    end
  end

  defp string_keyed(%{} = map) do
    Map.new(map, fn {k, v} -> {Generators.normalize_key(k), string_keyed(v)} end)
  end

  defp string_keyed(list) when is_list(list), do: Enum.map(list, &string_keyed/1)
  defp string_keyed(other), do: other
end
