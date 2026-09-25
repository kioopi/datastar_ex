defmodule Datastar.SSETest do
  use ExUnit.Case, async: true

  doctest Datastar.SSE

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

  describe "encode/1 data newline normalization" do
    test "CRLF in data normalizes to LF" do
      assert encode_to_binary(%{data: "one\r\ntwo"}) == "data: one\ndata: two\n\n"
    end

    test "lone CR normalizes to LF" do
      assert encode_to_binary(%{data: "one\rtwo"}) == "data: one\ndata: two\n\n"
    end

    test "mixed newline styles all normalize to LF" do
      assert encode_to_binary(%{data: "a\r\nb\rc\nd"}) ==
               "data: a\ndata: b\ndata: c\ndata: d\n\n"
    end

    test "one trailing newline yields a trailing empty data field" do
      assert encode_to_binary(%{data: "one\n"}) == "data: one\ndata: \n\n"
    end

    test "data of a single newline yields two empty data fields" do
      assert encode_to_binary(%{data: "\n"}) == "data: \ndata: \n\n"
    end

    test "data of two newlines yields three empty data fields" do
      assert encode_to_binary(%{data: "\n\n"}) == "data: \ndata: \ndata: \n\n"
    end

    test "trailing CRLF yields a trailing empty data field" do
      assert encode_to_binary(%{data: "one\r\n"}) == "data: one\ndata: \n\n"
    end

    test "U+FEFF inside a value is ordinary data, not a BOM" do
      assert encode_to_binary(%{data: "a﻿b"}) == "data: a﻿b\n\n"
    end
  end

  describe "encode/1 validation" do
    test "rejects a map without :data" do
      assert_raise ArgumentError, ~r/missing required :data/, fn ->
        Datastar.SSE.encode(%{event: "update"})
      end
    end

    test "rejects non-map input including keyword lists" do
      assert_raise ArgumentError, ~r/expected a map/, fn ->
        Datastar.SSE.encode(data: "x")
      end

      assert_raise ArgumentError, ~r/expected a map/, fn ->
        Datastar.SSE.encode("data: x")
      end

      assert_raise ArgumentError, ~r/expected a map/, fn ->
        Datastar.SSE.encode(nil)
      end
    end

    test "rejects string keys" do
      assert_raise ArgumentError, ~r/invalid SSE event/, fn ->
        Datastar.SSE.encode(%{"data" => "x"})
      end
    end

    test "rejects unknown keys, catching misspellings" do
      assert_raise ArgumentError, ~r/unknown key :rety/, fn ->
        Datastar.SSE.encode(%{data: "x", rety: 1})
      end
    end

    test "rejects non-binary data, event, and id" do
      for bad <- [%{data: 1}, %{data: "x", event: :update}, %{data: "x", id: 42}] do
        assert_raise ArgumentError, ~r/valid UTF-8 binary/, fn ->
          Datastar.SSE.encode(bad)
        end
      end
    end

    test "rejects malformed UTF-8 in every binary field" do
      malformed = <<0xFF, 0xFE>>

      for bad <- [
            %{data: malformed},
            %{data: "x", event: malformed},
            %{data: "x", id: malformed}
          ] do
        assert_raise ArgumentError, ~r/valid UTF-8 binary/, fn ->
          Datastar.SSE.encode(bad)
        end
      end
    end

    test "rejects CR, LF, and CRLF in :event" do
      for name <- ["a\nb", "a\rb", "a\r\nb"] do
        assert_raise ArgumentError, ~r/:event must not contain CR or LF/, fn ->
          Datastar.SSE.encode(%{data: "x", event: name})
        end
      end
    end

    test "rejects NULL, CR, LF, and CRLF in :id" do
      for id <- ["a\0b", "a\nb", "a\rb", "a\r\nb"] do
        assert_raise ArgumentError, ~r/:id must not contain NULL, CR, or LF/, fn ->
          Datastar.SSE.encode(%{data: "x", id: id})
        end
      end
    end

    test "rejects invalid retry values" do
      for retry <- [-1, 1.5, "2000", :fast, nil, true] do
        assert_raise ArgumentError, ~r/:retry must be a non-negative integer/, fn ->
          Datastar.SSE.encode(%{data: "x", retry: retry})
        end
      end
    end

    test "injection-shaped event and id values are rejected, not stripped" do
      assert_raise ArgumentError, fn ->
        Datastar.SSE.encode(%{data: "ok", event: "safe\ndata: injected"})
      end

      assert_raise ArgumentError, fn ->
        Datastar.SSE.encode(%{data: "ok", id: "42\n\nretry: 0"})
      end
    end
  end

  describe "encode_comment/1" do
    test "single-line comment encodes as one colon-prefixed line, no blank line" do
      assert comment_to_binary("keep-alive") == ": keep-alive\n"
    end

    test "empty comment encodes as a single empty comment line" do
      assert comment_to_binary("") == ": \n"
    end

    test "multiline comment becomes one comment line per logical line" do
      assert comment_to_binary("one\ntwo") == ": one\n: two\n"
    end

    test "CRLF and CR in comments normalize to LF" do
      assert comment_to_binary("one\r\ntwo\rthree") == ": one\n: two\n: three\n"
    end

    test "trailing empty logical lines are preserved" do
      assert comment_to_binary("x\n") == ": x\n: \n"
    end

    test "rejects malformed UTF-8 and non-binary comments" do
      assert_raise ArgumentError, ~r/invalid SSE comment/, fn ->
        Datastar.SSE.encode_comment(<<0xFF>>)
      end

      assert_raise ArgumentError, ~r/invalid SSE comment/, fn ->
        Datastar.SSE.encode_comment(:heartbeat)
      end
    end
  end

  defp encode_to_binary(event) do
    event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
  end

  defp comment_to_binary(comment) do
    comment |> Datastar.SSE.encode_comment() |> IO.iodata_to_binary()
  end
end
