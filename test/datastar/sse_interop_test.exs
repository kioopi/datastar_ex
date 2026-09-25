defmodule Datastar.SSEInteropTest do
  use ExUnit.Case, async: true

  # ServerSentEvents is an interoperability oracle, not the specification
  # (spec §2, §9). The characterization tests pin the oracle behaviors the
  # round-trip assertions depend on; if one fails after a dep upgrade, the
  # oracle changed, not the encoder.

  describe "oracle characterization" do
    test "empty event field decodes to event: \"\" (key present)" do
      assert decode(["event: \ndata: x\n\n"]) == [%{event: "", data: "x"}]
    end

    test "absent optional fields stay absent in the decoded map" do
      assert decode(["data: x\n\n"]) == [%{data: "x"}]
    end

    test "empty id and retry 0 survive decoding" do
      assert decode(["id: \nretry: 0\ndata: x\n\n"]) == [%{id: "", retry: 0, data: "x"}]
    end

    test "a chunk split between CR and LF is one line break, not two" do
      # Encoder output never contains CR (spec §7.1); this characterizes
      # the oracle on decoder-side input per spec §10.4.
      assert decode(["data: x\r", "\ndata: y\r\n\r\n"]) == [%{data: "x\ny"}]
    end
  end

  describe "encode/1 round-trips through ServerSentEvents" do
    test "multiline CRLF data round-trips normalized" do
      event = %{event: "message", id: "42", retry: 0, data: "one\r\ntwo\n"}
      expected = %{event | data: "one\ntwo\n"}

      assert decode([encode_binary(event)]) == [expected]
    end

    test "all data shapes from the spec's normalization table round-trip" do
      for data <- ["", "one", "one\ntwo", "one\n", "\n", "\n\n"] do
        assert decode([encode_binary(%{data: data})]) == [%{data: data}]
      end
    end

    test "frame-injection-shaped data stays one event with identical data" do
      data = "data: x\n\nevent: y"
      assert decode([encode_binary(%{data: data})]) == [%{data: data}]
    end

    test "comments decode to no events" do
      assert decode([comment_binary("heartbeat")]) == []
      assert decode([comment_binary("one\ntwo\n")]) == []
      assert decode([comment_binary("")]) == []
    end

    test "a comment between events changes nothing" do
      stream = [
        encode_binary(%{data: "a"}),
        comment_binary("hb"),
        encode_binary(%{data: "b"})
      ]

      assert decode(stream) == [%{data: "a"}, %{data: "b"}]
    end

    test "concatenated events decode in order" do
      stream = [encode_binary(%{id: "1", data: "first"}), encode_binary(%{data: "second"})]
      assert decode(stream) == [%{id: "1", data: "first"}, %{data: "second"}]
    end
  end

  describe "chunk-boundary invariance (deterministic)" do
    test "one byte per chunk equals one whole binary" do
      binary = encode_binary(%{event: "update", id: "42", data: "日本\nlines"})
      chunks = for <<byte <- binary>>, do: <<byte>>

      assert decode(chunks) == decode([binary])
    end

    test "every single split point of a short unicode fixture" do
      binary = encode_binary(%{data: "héllo\n﻿"})

      for split <- 1..(byte_size(binary) - 1) do
        <<a::binary-size(^split), b::binary>> = binary
        assert decode([a, b]) == decode([binary]), "differs at split #{split}"
      end
    end
  end

  defp decode(chunks) do
    chunks |> ServerSentEvents.decode_stream() |> Enum.to_list()
  end

  defp encode_binary(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
  defp comment_binary(c), do: c |> Datastar.SSE.encode_comment() |> IO.iodata_to_binary()
end
