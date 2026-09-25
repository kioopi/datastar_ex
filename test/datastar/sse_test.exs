defmodule Datastar.SSETest do
  use ExUnit.Case, async: true

  describe "encode/1 canonical bytes" do
    test "data-only event" do
      assert encode_to_binary(%{data: "hello"}) == "data: hello\n\n"
    end

    test "all fields present, canonical order event/id/retry/data" do
      event = %{event: "update", id: "42", retry: 2_000, data: "first\nsecond"}

      assert encode_to_binary(event) ==
               "event: update\nid: 42\nretry: 2000\ndata: first\ndata: second\n\n"
    end

    test "absent optional fields are omitted entirely" do
      assert encode_to_binary(%{data: "x"}) == "data: x\n\n"
      assert encode_to_binary(%{id: "1", data: "x"}) == "id: 1\ndata: x\n\n"
    end

    test "empty event, id, data and retry: 0 encode explicitly" do
      event = %{event: "", id: "", retry: 0, data: ""}
      assert encode_to_binary(event) == "event: \nid: \nretry: 0\ndata: \n\n"
    end

    test "very large retry encodes as plain ASCII decimal" do
      assert encode_to_binary(%{retry: 999_999_999_999_999, data: "x"}) ==
               "retry: 999999999999999\ndata: x\n\n"
    end

    test "leading spaces and colons in values are preserved after the delimiter space" do
      event = %{event: " custom:type", data: " value: 1"}
      assert encode_to_binary(event) == "event:  custom:type\ndata:  value: 1\n\n"
    end

    test "NULL is allowed in data and event" do
      assert encode_to_binary(%{event: "a\0b", data: "c\0d"}) ==
               "event: a\0b\ndata: c\0d\n\n"
    end

    test "non-ASCII multi-byte unicode passes through unchanged" do
      assert encode_to_binary(%{event: "héllo", id: "καλά", data: "日本語 🎉"}) ==
               "event: héllo\nid: καλά\ndata: 日本語 🎉\n\n"
    end

    test "output never starts with a BOM" do
      refute String.starts_with?(encode_to_binary(%{data: "x"}), "﻿")
    end

    test "every encoded event ends with exactly one blank line" do
      binary = encode_to_binary(%{data: "x"})
      assert String.ends_with?(binary, "\n\n")
      refute String.ends_with?(binary, "\n\n\n")
    end

    test "two encoded events concatenate into a valid stream" do
      stream =
        IO.iodata_to_binary([
          Datastar.SSE.encode(%{id: "1", data: "first"}),
          Datastar.SSE.encode(%{data: "second"})
        ])

      assert stream == "id: 1\ndata: first\n\ndata: second\n\n"
    end
  end

  defp encode_to_binary(event) do
    event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
  end
end
