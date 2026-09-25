defmodule Datastar.SSEPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Datastar.SSE.Generators
  alias Datastar.SSE.WhatwgEventStreamModel, as: Model

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
      refute String.starts_with?(binary, "﻿")
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
      assert length(interpreted.events) == length(events)

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

      for line <- String.split(comment_binary, "\n", trim: true) do
        assert String.starts_with?(line, ": ")
      end

      assert decode([comment_binary]) == []

      interleaved = [encode_binary(event), comment_binary, encode_binary(event)]
      assert decode(interleaved) == [normalize(event), normalize(event)]
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
          <<chunk::binary-size(size), remainder::binary>> = rest
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
