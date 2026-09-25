defmodule Datastar.SSEWhatwgTest do
  use ExUnit.Case, async: true

  alias Datastar.SSE.WhatwgEventStreamModel, as: Model

  describe "encoded events under WHATWG interpretation" do
    test "a data-only event dispatches once as type message" do
      binary = encode_binary(%{data: "hello"})

      assert %{events: [%{type: "message", data: "hello", last_event_id: ""}]} =
               Model.interpret(binary)
    end

    test "empty event field dispatches as type message" do
      assert %{events: [%{type: "message"}]} =
               Model.interpret(encode_binary(%{event: "", data: "x"}))
    end

    test "custom event type dispatches with that type" do
      assert %{events: [%{type: "update"}]} =
               Model.interpret(encode_binary(%{event: "update", data: "x"}))
    end

    test "empty data still dispatches exactly one event with empty data" do
      assert %{events: [%{data: ""}]} = Model.interpret(encode_binary(%{data: ""}))
    end

    test "trailing-newline data shapes survive the final-LF removal rule" do
      for data <- ["", "one", "one\ntwo", "one\n", "\n", "\n\n"] do
        assert %{events: [%{data: ^data}]} = Model.interpret(encode_binary(%{data: data}))
      end
    end

    test "removing the final blank line prevents dispatch (EOF discards)" do
      binary = encode_binary(%{data: "pending"})
      truncated = String.replace_suffix(binary, "\n", "")

      assert %{events: []} = Model.interpret(truncated)
    end

    test "last event ID persists onto later events without an id field" do
      stream = encode_binary(%{id: "1", data: "first"}) <> encode_binary(%{data: "second"})

      assert %{events: [%{last_event_id: "1"}, %{last_event_id: "1"}]} = Model.interpret(stream)
    end

    test "empty id resets the persistent last event ID" do
      stream =
        encode_binary(%{id: "1", data: "a"}) <>
          encode_binary(%{id: "", data: "reset"}) <> encode_binary(%{data: "after"})

      assert %{events: [_, %{last_event_id: ""}, %{last_event_id: ""}]} = Model.interpret(stream)
    end

    test "retry sets the reconnection time" do
      assert %{reconnection_time: 2000} =
               Model.interpret(encode_binary(%{retry: 2000, data: "x"}))

      assert %{reconnection_time: 0} = Model.interpret(encode_binary(%{retry: 0, data: "x"}))
    end

    test "an id in an unterminated block is never committed" do
      assert %{last_event_id: ""} = Model.interpret("id: 9\ndata: x")
    end

    test "a blank line commits the id buffer even without a dispatch" do
      assert %{events: [], last_event_id: "9"} = Model.interpret("id: 9\n\n")
    end

    test "one leading BOM is stripped from the stream" do
      assert %{events: [%{data: "x"}]} = Model.interpret("﻿data: x\n\n")
    end

    test "comments dispatch nothing and change no state" do
      binary = "hb" |> Datastar.SSE.encode_comment() |> IO.iodata_to_binary()

      assert %{events: [], last_event_id: "", reconnection_time: nil} = Model.interpret(binary)
    end

    test "frame-injection-shaped data dispatches exactly one event with identical data" do
      data = "data: x\n\nevent: y"

      assert %{events: [%{type: "message", data: ^data}]} =
               Model.interpret(encode_binary(%{data: data}))
    end

    test "leading value spaces survive: parser removes only the delimiter space" do
      assert %{events: [%{data: " padded"}]} = Model.interpret(encode_binary(%{data: " padded"}))
    end
  end

  defp encode_binary(event), do: event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
end
