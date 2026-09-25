defmodule Datastar.SSEPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.SSE.Generators
  alias Datastar.SSE.WhatwgEventStreamModel, as: Model

  @bom <<0xEF, 0xBB, 0xBF>>

  test "generators cover injection-prone and boundary shapes" do
    events = Enum.take(Generators.event(), 1_000)
    names = Enum.flat_map(events, &(Map.take(&1, [:event, :id]) |> Map.values()))

    assert Enum.any?(names, &String.contains?(&1, ":")), "no colon in any event/id"
    assert Enum.any?(names, &String.starts_with?(&1, " ")), "no leading space in any event/id"
    assert Enum.any?(names, &(&1 =~ ~r/[a-zA-Z]/)), "no ASCII letters in any event/id"

    assert Enum.any?(events, &String.contains?(Map.get(&1, :event, ""), "\0")),
           "no NULL in any :event"

    assert Enum.any?(events, &String.contains?(&1.data, "\0")), "no NULL in any :data"
    assert Enum.any?(events, &(Map.get(&1, :retry, 0) > 1_000)), "no large :retry"
  end

  property "valid events survive canonical encoding and independent decoding" do
    check all(event <- Generators.event()) do
      assert decode([encode_binary(event)]) == [normalize(event)]
    end
  end

  property "canonical output invariants hold for every valid event" do
    check all(event <- Generators.event()) do
      iodata = Datastar.SSE.encode(event)
      binary = IO.iodata_to_binary(iodata)

      assert String.valid?(binary)
      refute String.contains?(binary, "\r")
      refute String.starts_with?(binary, @bom)
      assert String.ends_with?(binary, "\n\n")

      assert [decoded] = decode([binary])
      assert encode_binary(decoded) == binary, "canonicalization is not stable"
    end
  end

  property "decoding is invariant under arbitrary byte-level chunking" do
    check all(
            event <- Generators.event(),
            sizes <- list_of(positive_integer(), min_length: 1)
          ) do
      binary = encode_binary(event)
      chunks = split_by_sizes(binary, sizes)

      assert decode(chunks) == decode([binary])
    end
  end

  property "event sequences decode in order and browser state accumulates" do
    check all(
            events <- list_of(Generators.event(), min_length: 1, max_length: 5),
            sizes <- list_of(positive_integer(), min_length: 1)
          ) do
      binary = events |> Enum.map(&Datastar.SSE.encode/1) |> IO.iodata_to_binary()

      assert decode(split_by_sizes(binary, sizes)) == Enum.map(events, &normalize/1)

      interpreted = Model.interpret(binary)

      {expected_events, _last_id} =
        Enum.map_reduce(events, "", fn event, last_id ->
          id = Map.get(event, :id, last_id)

          type =
            case Map.get(event, :event, "") do
              "" -> "message"
              custom -> custom
            end

          {%{type: type, data: normalize(event).data, last_event_id: id}, id}
        end)

      assert interpreted.events == expected_events

      expected_retry =
        events
        |> Enum.filter(&Map.has_key?(&1, :retry))
        |> List.last()
        |> then(&(&1 && &1.retry))

      assert interpreted.reconnection_time == expected_retry
    end
  end

  property "comments encode canonically and never affect events" do
    check all(comment <- Generators.comment(), event <- Generators.event()) do
      comment_binary = comment |> Datastar.SSE.encode_comment() |> IO.iodata_to_binary()

      assert String.valid?(comment_binary)
      refute String.contains?(comment_binary, "\r")
      assert String.ends_with?(comment_binary, "\n")
      # No blank line is ever appended: every line carries the ": " prefix,
      # so a comment can never terminate a pending event (spec §6.2).
      refute String.contains?(comment_binary, "\n\n")

      for line <- String.split(comment_binary, "\n", trim: true) do
        assert String.starts_with?(line, ": ")
      end

      assert decode([comment_binary]) == []

      interleaved = [encode_binary(event), comment_binary, encode_binary(event)]
      assert decode(interleaved) == [normalize(event), normalize(event)]

      expected_data = normalize(event).data

      assert %{events: [%{data: ^expected_data}, %{data: ^expected_data}]} =
               Model.interpret(IO.iodata_to_binary(interleaved))
    end
  end

  property "every constructed invalid event raises ArgumentError" do
    check all(event <- Generators.invalid_event()) do
      assert_raise ArgumentError, fn -> Datastar.SSE.encode(event) end
    end
  end

  # Byte-oriented on purpose: cuts may land inside multi-byte UTF-8
  # sequences (spec §12.4).
  defp split_by_sizes(binary, sizes) do
    sizes
    |> Enum.reduce_while({[], binary}, fn size, {acc, rest} ->
      case rest do
        "" ->
          {:halt, {acc, ""}}

        _ when byte_size(rest) <= size ->
          {:halt, {[rest | acc], ""}}

        _ ->
          <<chunk::binary-size(^size), remainder::binary>> = rest
          {:cont, {[chunk | acc], remainder}}
      end
    end)
    |> then(fn {acc, rest} ->
      case rest do
        "" -> Enum.reverse(acc)
        _ -> Enum.reverse([rest | acc])
      end
    end)
  end

  # Test-side normalizer, independent of the production implementation
  # (spec §12.2): the expected value must not be computed by the code
  # under test.
  defp normalize(%{data: data} = event) do
    %{event | data: data |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")}
  end

  defp encode_binary(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
  defp decode(chunks), do: chunks |> ServerSentEvents.decode_stream() |> Enum.to_list()
end
