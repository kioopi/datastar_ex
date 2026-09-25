# Encoder benchmarks

`bench/encode_bench.exs` measures `Datastar.SSE.encode/1` and
`encode_comment/1` with [Benchee](https://github.com/bencheeorg/benchee).
It mirrors the structure of the
[`server_sent_events` parse benchmark](https://github.com/benjreinhart/server_sent_events/blob/main/bench/parse_bench.exs)
so results from the two libraries read side by side — useful if the
encoder is ever proposed upstream.

It is deliberately **not part of `mix ci`**: timing is machine- and
load-dependent, so a benchmark makes a poor pass/fail gate. Treat it as a
comparison tool. Absolute numbers mean little; what matters is the
*relative* reading — encoder vs. baseline, and this commit vs. the last
one whenever the encoder changes.

## Running

```sh
mix run bench/encode_bench.exs
```

A full run takes a few minutes. For a quick smoke run:

```sh
BENCH_TIME=0.1 BENCH_WARMUP=0 BENCH_MEMORY_TIME=0.1 mix run bench/encode_bench.exs
```

The three environment variables override Benchee's per-scenario seconds
(`time`, `warmup`, `memory_time`; defaults 5 / 2 / 2).

## What is measured

**Inputs** model Datastar's real payload shapes. The most important is
the full-page HTML morph — the body of a `datastar-patch-elements` event
when Datastar replaces a whole page, which is the workload behind its
"fast full-page morphs" claim:

| Input | Shape |
| --- | --- |
| 100 KB / 1 MB HTML morph | many moderate HTML lines, LF endings |
| 1 MB HTML morph (CRLF) | the same, CRLF endings (template-engine output) |
| 64 KB / 1 MB single line | one huge logical line, no splitting work |
| 10k short lines | line-count-dominated payload |

**Jobs** run per input:

| Job | Purpose |
| --- | --- |
| `encode (iodata)` | the real encoder, output left as iodata |
| `encode \|> iodata_to_binary` | the same plus flattening, for callers that need one binary |
| `naive concat baseline` | a reference encoder building one binary by concatenation |
| `UTF-8 validation floor` | `String.valid?/1` alone — the lower bound any validating encoder pays |

A second, input-less run covers 1000 small `datastar-patch-signals`
events (iodata vs. naive) and the heartbeat comment.

Two methodology points keep the comparison honest:

- The naive baseline **validates its input exactly like the real
  encoder**. An earlier version skipped the UTF-8 scan and "won" every
  scenario — a misleading result. The baseline exists to isolate the
  build strategy (iodata vs. concatenation), not to reward skipping
  spec-mandated work.
- At startup the script asserts the baseline produces **byte-identical
  canonical output** to `encode/1`; if the two ever diverge, the run
  aborts rather than compare different work.

## Findings (2026-09-25)

Measured on a 13th-gen i7-1370P, Elixir 1.20.4 / OTP 29, JIT enabled.
Re-run on your own machine before drawing conclusions; only the ratios
below are expected to transfer.

Cost decomposition for a 1 MB HTML morph (~2.9 ms total):

| Component | ~ms / MB | Share |
| --- | --- | --- |
| `String.valid?/1` UTF-8 scan | 1.2 | ~41% |
| `:binary.split` on CRLF/CR/LF | 1.3 | ~44% |
| Building the iodata | 0.2 | ~6% |
| Flattening (`IO.iodata_to_binary/1`) | +0.5 | only if the caller flattens |

1. **The iodata design pays, modestly, at morph scale.** With validation
   equalized, `encode (iodata)` beats the naive baseline on the 1 MB
   morph (~2.97 ms vs. ~3.22 ms), and the iodata build itself is nearly
   free. The practical consequence: pass the returned iodata straight to
   `Plug.Conn.chunk/2`; flattening first donates ~0.5 ms/MB back.
2. **The dominant fixed cost is the spec-mandated validation scan**, now
   visible directly in the report as the "UTF-8 validation floor" job.
   It is O(n) and irreducible while the spec requires every binary field
   to pass `String.valid?/1`.
3. **Small events live in a different regime.** For 1000 tiny signal
   patches, naive concatenation slightly outperforms iodata: per-event
   list overhead dominates, and the BEAM's binary-append optimization is
   excellent at small sizes. At roughly 1.5 µs per event either way this
   is irrelevant to real workloads, but it is worth knowing before
   claiming iodata is universally faster.

## If morph encoding ever becomes a bottleneck

In descending order of preference:

1. **Do nothing until a measurement says otherwise.** ~3 ms per megabyte
   of morphed HTML is far below network and DOM-morph cost for the same
   payload. Re-run the suite after encoder changes and compare ratios;
   act on regressions, not on absolute numbers.
2. **Keep output as iodata end to end.** The cheapest 0.5 ms/MB is the
   flatten nobody needed. The future transport layer should hand
   `encode/1`'s result directly to the connection.
3. **Add an opt-in trusted-input path.** The validation floor can only
   be removed by not validating. If profiling ever justifies it, add an
   explicit escape hatch (for example `encode(event, validate: false)`)
   for data the Datastar layer already knows is valid UTF-8 because it
   came from the template engine. This weakens the encoder's central
   guarantee, so it belongs behind a loud, documented option — it is a
   spec §15 "deferred evolution" decision, not a default.
4. **Fuse validation into the split.** A hand-rolled UTF-8 walk could
   validate and find newlines in one pass instead of two (~40% of the
   remaining cost). That trades the clarity of two obvious standard
   calls for bespoke binary-matching code; only worth it with a
   measurement in hand, and ideally as a contribution to an upstream
   `server_sent_events` encoder where the maintenance cost is shared.
