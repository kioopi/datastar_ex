# Benchmarks for `Datastar.SSE.encode/1` and `encode_comment/1`.
#
# Run with:
#
#     mix run bench/encode_bench.exs
#
# Quick smoke run:
#
#     BENCH_TIME=0.1 BENCH_WARMUP=0 BENCH_MEMORY_TIME=0.1 mix run bench/encode_bench.exs
#
# Not part of `mix ci`: timing is machine-dependent, so this is a
# comparison tool — run it before/after an encoder change, or to produce
# numbers for an upstreaming proposal (spec §13). The interesting reads
# are relative: the iodata encoder vs. the naive-concatenation baseline,
# and memory (allocation) as much as throughput. The payload shapes
# mirror Datastar's real workload, above all the full-page HTML morph
# that `datastar-patch-elements` carries.

defmodule Datastar.SSE.Bench do
  @moduledoc false

  @doc """
  Reference encoder building one binary by concatenation.

  Produces byte-identical canonical output for the benchmarked events;
  exists only as the baseline the iodata design is measured against.
  """
  def naive_encode(%{data: data} = event) do
    # Validate like encode/1 does, so the comparison isolates the
    # iodata-vs-concatenation build strategy rather than rewarding the
    # baseline for skipping the spec-mandated UTF-8 scan.
    unless String.valid?(data) do
      raise ArgumentError, "invalid data"
    end

    head =
      case event do
        %{event: name} -> "event: " <> name <> "\n"
        _ -> ""
      end

    data
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.reduce(head, fn line, acc -> acc <> "data: " <> line <> "\n" end)
    |> Kernel.<>("\n")
  end

  @doc "An HTML document of roughly `target_bytes`, one element per line."
  def html_page(target_bytes, newline \\ "\n") do
    line = ~s(<div class="row" data-signals="{open: false}"><span>Item</span></div>)
    count = div(target_bytes, byte_size(line) + 3) + 1

    Enum.map_join(1..count, newline, fn i -> line <> Integer.to_string(i) end)
  end

  @doc "A single logical line of `bytes` bytes."
  def single_line(bytes), do: :binary.copy("x", bytes)

  @doc "`count` short logical lines."
  def short_lines(count) do
    Enum.map_join(1..count, "\n", fn i -> "line " <> Integer.to_string(i) end)
  end

  @doc "A small `datastar-patch-signals`-shaped event."
  def small_signal_event(i) do
    %{event: "datastar-patch-signals", data: ~s(signals {"count":#{i}})}
  end
end

alias Datastar.SSE.Bench

time = String.to_float(System.get_env("BENCH_TIME", "5.0"))
warmup = String.to_float(System.get_env("BENCH_WARMUP", "2.0"))
memory_time = String.to_float(System.get_env("BENCH_MEMORY_TIME", "2.0"))

# Sanity: the baseline must produce the encoder's exact canonical bytes,
# otherwise the comparison is meaningless.
sanity = %{event: "datastar-patch-elements", data: Bench.html_page(10_000, "\r\n")}

if IO.iodata_to_binary(Datastar.SSE.encode(sanity)) != Bench.naive_encode(sanity) do
  raise "naive baseline diverged from Datastar.SSE.encode/1"
end

inputs = %{
  "064 KB single line" => Bench.single_line(64 * 1024),
  "1 MB single line" => Bench.single_line(1024 * 1024),
  "100 KB HTML morph" => Bench.html_page(100 * 1024),
  "1 MB HTML morph" => Bench.html_page(1024 * 1024),
  "1 MB HTML morph (CRLF)" => Bench.html_page(1024 * 1024, "\r\n"),
  "10k short lines" => Bench.short_lines(10_000)
}

Benchee.run(
  %{
    "encode (iodata)" => fn html ->
      Datastar.SSE.encode(%{event: "datastar-patch-elements", data: html})
    end,
    "encode |> iodata_to_binary" => fn html ->
      %{event: "datastar-patch-elements", data: html}
      |> Datastar.SSE.encode()
      |> IO.iodata_to_binary()
    end,
    "naive concat baseline" => fn html ->
      Bench.naive_encode(%{event: "datastar-patch-elements", data: html})
    end,
    "UTF-8 validation floor" => fn html ->
      # The spec-mandated String.valid?/1 scan alone: the lower bound any
      # validating encoder pays before it builds a single byte of output.
      String.valid?(html)
    end
  },
  inputs: inputs,
  time: time,
  warmup: warmup,
  memory_time: memory_time
)

Benchee.run(
  %{
    "1000 small signal events (iodata)" => fn ->
      Enum.map(1..1000, &Datastar.SSE.encode(Bench.small_signal_event(&1)))
    end,
    "1000 small signal events (naive)" => fn ->
      Enum.map(1..1000, &Bench.naive_encode(Bench.small_signal_event(&1)))
    end,
    "heartbeat comment" => fn ->
      Datastar.SSE.encode_comment("keep-alive")
    end
  },
  time: time,
  warmup: warmup,
  memory_time: memory_time
)
