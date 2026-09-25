defmodule Datastar.SSE.WhatwgEventStreamModel do
  @moduledoc """
  Test-only reference model of the WHATWG `text/event-stream`
  interpretation algorithm (HTML Standard §9.2.6).

  Written from the standard's rules, independently of the production
  encoder, to verify browser-level semantics that field-level decoders
  do not model: default event type, blank-line dispatch, last-event-ID
  persistence and reset, and reconnection time.
  """

  defstruct data_buffer: [],
            saw_data_field: false,
            event_type_buffer: "",
            last_event_id: "",
            reconnection_time: nil,
            events: []

  @doc """
  Interprets a complete stream binary; returns dispatched events and
  final stream state. Incomplete trailing data (no final newline) is
  discarded, as at EOF in the standard.
  """
  def interpret(binary) when is_binary(binary) do
    lines = complete_lines(binary)
    state = Enum.reduce(lines, %__MODULE__{}, &process_line/2)

    %{
      events: Enum.reverse(state.events),
      last_event_id: state.last_event_id,
      reconnection_time: state.reconnection_time
    }
  end

  # Physical lines end in CRLF, CR, or LF; a trailing fragment without a
  # terminator is never processed.
  defp complete_lines(binary) do
    binary
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.drop(-1)
  end

  defp process_line("", state), do: dispatch(state)
  defp process_line(":" <> _comment, state), do: state

  defp process_line(line, state) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    process_field(field, value, state)
  end

  defp process_field("event", value, state), do: %{state | event_type_buffer: value}

  defp process_field("data", value, state) do
    %{state | data_buffer: [state.data_buffer, value, "\n"], saw_data_field: true}
  end

  defp process_field("id", value, state) do
    if String.contains?(value, "\0"), do: state, else: %{state | last_event_id: value}
  end

  defp process_field("retry", value, state) do
    if value =~ ~r/\A[0-9]+\z/ do
      %{state | reconnection_time: String.to_integer(value)}
    else
      state
    end
  end

  defp process_field(_unknown_field, _value, state), do: state

  defp dispatch(%{saw_data_field: false} = state) do
    %{state | data_buffer: [], event_type_buffer: ""}
  end

  defp dispatch(state) do
    data =
      state.data_buffer
      |> IO.iodata_to_binary()
      |> String.replace_suffix("\n", "")

    type = if state.event_type_buffer == "", do: "message", else: state.event_type_buffer

    event = %{type: type, data: data, last_event_id: state.last_event_id}

    %{
      state
      | events: [event | state.events],
        data_buffer: [],
        saw_data_field: false,
        event_type_buffer: ""
    }
  end
end
