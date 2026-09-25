# `Datastar.SSE` encoder specification

**Status:** Draft for the first pre-1.0 implementation  
**Version:** 0.1  
**Date:** 2026-09-25  
**Scope:** Pure Server-Sent Events encoding; no HTTP or Datastar event semantics

## 1. Purpose

`Datastar.SSE` is the protocol foundation of the Elixir Datastar package. It accepts a semantic Server-Sent Events (SSE) event and serializes it into a canonical `text/event-stream` representation.

The module has two jobs:

1. produce valid, safe, predictable SSE wire data; and
2. make the later Datastar event constructors independent of SSE framing details.

The core contract is:

```text
semantic SSE event
        │
        ▼
Datastar.SSE.encode/1
        │
        ▼
canonical UTF-8 text/event-stream iodata
```

Datastar-specific modules will eventually construct events such as `datastar-patch-elements` and `datastar-patch-signals`. They will not write `event:`, `data:`, delimiters, or line endings themselves.

This document uses **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in their usual normative sense.

## 2. Standards claim

The [WHATWG HTML Standard, §9.2 Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) specifies:

- the `text/event-stream` grammar;
- UTF-8 decoding;
- physical line endings;
- field parsing;
- `data`, `event`, `id`, and `retry` interpretation;
- blank-line dispatch;
- EventSource state such as the last event ID and reconnection time.

It does **not** define a canonical server-side serialization algorithm. Multiple byte sequences can represent the same semantic event.

The compliance claim for `Datastar.SSE` is therefore:

> `Datastar.SSE` produces one canonical SSE representation. Every accepted event is serialized as valid WHATWG `text/event-stream` data, and interpreting that data according to the WHATWG algorithm yields the requested normalized event and stream-state changes.

The test suite MUST distinguish three related contracts:

| Contract | Meaning |
| --- | --- |
| Canonical encoding | The exact bytes chosen by this library |
| WHATWG semantics | What a conforming EventSource implementation does with those bytes |
| `ServerSentEvents` interoperability | What the independent Elixir decoder returns |

`ServerSentEvents` is an interoperability oracle, not the specification.

## 3. Scope

### 3.1 Included in this milestone

- a semantic event type compatible with `ServerSentEvents.event()`;
- strict input validation;
- newline normalization for event data;
- canonical SSE event encoding to iodata;
- canonical comment encoding for future heartbeat use;
- exact wire-format tests;
- WHATWG-derived semantic tests;
- interoperability tests using `server_sent_events`;
- property-based tests using StreamData;
- arbitrary transport chunk-boundary tests.

### 3.2 Explicitly out of scope

- `Plug.Conn` integration;
- HTTP response headers or status codes;
- starting or owning a chunked response;
- Bandit, Cowboy, or Phoenix integration;
- connection processes or supervision;
- heartbeat scheduling;
- PubSub or subscription mechanisms;
- reconnecting clients;
- storing or applying `Last-Event-ID`;
- applying retry delays;
- compression;
- Datastar event names and payload construction;
- decoding SSE in production code;
- arbitrary raw SSE fields or control blocks with no `data` field.

Those exclusions are architectural boundaries, not missing parts of the encoder.

## 4. Module structure

The first implementation SHOULD remain small:

```text
lib/
  datastar/
    sse.ex

test/
  datastar/
    sse_test.exs
    sse_property_test.exs
    sse_whatwg_test.exs

  support/
    sse_generators.ex
    whatwg_event_stream_model.ex
```

### `Datastar.SSE`

The public production module owns:

- the event type;
- `encode/1`;
- `encode_comment/1`;
- validation;
- internal line-ending normalization;
- canonical serialization.

No production dependency is required.

### `Datastar.SSE.Generators`

A test-support module owns StreamData generators for valid and invalid values. It MUST NOT be compiled in production.

### `Datastar.SSE.WhatwgEventStreamModel`

A small, test-only reference model owns the subset of the WHATWG interpretation algorithm needed to evaluate the encoder's output. It tracks:

- the data buffer;
- the event-type buffer;
- the last-event-ID buffer;
- the EventSource last event ID;
- reconnection time;
- event dispatch at blank lines.

This model MUST be written from the WHATWG rules, not by calling production encoder helpers. Its purpose is to test browser semantics that `ServerSentEvents` intentionally does not model.

If the production module becomes difficult to navigate, private implementation code MAY later move to `Datastar.SSE.Encoder` with `@moduledoc false`. The public API MUST remain on `Datastar.SSE`; the initial implementation should not split modules merely in anticipation of future complexity.

## 5. Semantic event model

The public type is:

```elixir
@type event :: %{
        required(:data) => String.t(),
        optional(:event) => String.t(),
        optional(:id) => String.t(),
        optional(:retry) => non_neg_integer()
      }
```

Example:

```elixir
%{
  event: "update",
  id: "42",
  retry: 2_000,
  data: "first\nsecond"
}
```

This model is intentionally the same shape as the event maps returned by `ServerSentEvents`. It represents field-level SSE semantics, not a browser `MessageEvent` object:

- an absent `:event` key is different at the map level from `event: ""`, even though both dispatch as browser event type `"message"`;
- `:retry` is a stream-state instruction, not a property of the browser `MessageEvent`;
- an `:id` field updates persistent EventSource state, while the map describes only the current encoded block.

### 5.1 Accepted keys

Only `:data`, `:event`, `:id`, and `:retry` are accepted.

The encoder MUST reject:

- maps without `:data`;
- string keys such as `"data"`;
- unknown keys;
- non-map input.

Rejecting unknown keys prevents misspellings and unsupported fields from disappearing silently.

### 5.2 Field requirements

| Key | Required | Accepted value | Additional rules |
| --- | --- | --- | --- |
| `:data` | yes | valid UTF-8 binary | CRLF and CR are normalized to LF; empty string is valid |
| `:event` | no | valid UTF-8 binary | MUST NOT contain CR or LF; empty string is valid |
| `:id` | no | valid UTF-8 binary | MUST NOT contain NULL, CR, or LF; empty string is valid |
| `:retry` | no | non-negative integer | zero is valid; encoded in ASCII base-10 |

Elixir binaries are not automatically valid UTF-8. Every binary field and comment MUST pass `String.valid?/1` before encoding.

### 5.3 Characters deliberately allowed

The validation rules MUST NOT be stricter than needed for faithful encoding:

- `:data` MAY contain NULL, colons, leading spaces, and any other valid Unicode scalar value;
- `:event` MAY contain NULL, colons, and leading spaces;
- `:id` MAY contain colons and leading spaces;
- non-ASCII Unicode is valid in all binary fields;
- an empty `:id` is valid and resets the EventSource last event ID.

The encoder adds one delimiter space after the colon. If the value itself starts with a space, the wire line contains two spaces. A conforming parser removes only the first delimiter space, preserving the value's leading space.

### 5.4 Why `:id` rejects NULL

The WHATWG parser ignores an `id` field whose value contains U+0000 NULL. Encoding such a value would therefore fail to produce the requested ID. The standard also describes the `Last-Event-ID` value space as UTF-8 text excluding NULL, LF, and CR. `Datastar.SSE` rejects all three rather than silently producing an ineffective or unsafe field.

### 5.5 Why event and ID newlines are rejected

CR and LF terminate physical SSE lines. They cannot be represented inside an `event` or `id` field value and could otherwise inject extra fields or events. The encoder MUST reject them rather than strip, replace, or escape them.

## 6. Public API

### 6.1 `encode/1`

```elixir
@spec encode(event()) :: iodata()
def encode(event)
```

`encode/1` validates and canonically serializes one semantic event.

Example:

```elixir
event = %{
  event: "update",
  id: "42",
  retry: 2_000,
  data: "first\nsecond"
}

event
|> Datastar.SSE.encode()
|> IO.iodata_to_binary()
```

Result:

```text
event: update
id: 42
retry: 2000
data: first
data: second

```

The returned value MUST be valid iodata. Callers may convert it to a binary, write it to an IO device, or eventually pass it to `Plug.Conn.chunk/2` without an intermediate flattening step.

Invalid caller input is a programming error. `encode/1` MUST raise `ArgumentError` with a field-specific message. The first milestone does not add a second tuple-returning API or a custom exception. Tests SHOULD assert the error class and stable identifying phrase, not an elaborate full message.

Representative messages:

```text
invalid SSE event: missing required :data
invalid SSE event: :event must not contain CR or LF
invalid SSE event: :id must not contain NULL, CR, or LF
invalid SSE event: :retry must be a non-negative integer
invalid SSE event: unknown key :rety
```

### 6.2 `encode_comment/1`

```elixir
@spec encode_comment(String.t()) :: iodata()
def encode_comment(comment)
```

`encode_comment/1` serializes comment text into one or more canonical SSE comment lines.

```elixir
Datastar.SSE.encode_comment("keep-alive")
# => [": ", "keep-alive", "\n"]

Datastar.SSE.encode_comment("one\ntwo")
# wire form:
# : one
# : two
```

Requirements:

- input MUST be a valid UTF-8 binary;
- CRLF and CR MUST normalize to LF;
- every normalized logical line MUST become `: VALUE\n`;
- trailing empty logical lines MUST be preserved;
- the function MUST NOT append a blank line after the comment;
- it MUST NOT start timers, schedule heartbeats, or write to a connection.

A comment line is ignored by the WHATWG parser. The single terminating LF is sufficient to complete it. A later transport layer may send the returned iodata as a heartbeat.

## 7. Canonical event encoding

### 7.1 Canonical choices

For every accepted event, the encoder MUST produce exactly one form:

- UTF-8 only;
- no leading byte-order mark;
- LF (`U+000A`) physical line endings only;
- lowercase standard field names;
- exactly one ASCII space between the colon and the encoded value;
- fields ordered as `event`, `id`, `retry`, then `data`;
- optional fields omitted when their keys are absent;
- one `data` field for every normalized logical data line;
- exactly one final blank line after the event;
- no extra fields.

The field order is not required by WHATWG, but it gives stable output and matches the [Datastar SDK ADR](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md), which requires event, optional ID, optional retry, data lines, and an event terminator in that order.

### 7.2 Data newline normalization

Before serialization, `:data` MUST be normalized in this order:

1. replace every CRLF pair with LF;
2. replace every remaining CR with LF;
3. leave existing LF unchanged.

Formally:

```text
CRLF → LF
CR   → LF
LF   → LF
```

This is a semantic normalization. SSE field values cannot contain physical CR or LF, and the WHATWG data buffer always joins multiple `data` fields with LF. Consequently, CRLF, CR, and LF are not distinguishable in the `MessageEvent.data` value.

The test helper MAY expose this operation as `normalize_data/1`; it is not part of the public API.

### 7.3 Data-line splitting

The normalized data MUST be split on LF while preserving empty components, including the final component:

```elixir
String.split(normalized_data, "\n", trim: false)
```

Each resulting component is serialized as:

```text
data: COMPONENT\n
```

Preserving trailing empty components is essential:

| Semantic data | Canonical data fields | Browser `event.data` |
| --- | --- | --- |
| `""` | `data: \n` | `""` |
| `"one"` | `data: one\n` | `"one"` |
| `"one\ntwo"` | `data: one\ndata: two\n` | `"one\ntwo"` |
| `"one\n"` | `data: one\ndata: \n` | `"one\n"` |
| `"\n"` | `data: \ndata: \n` | `"\n"` |
| `"\n\n"` | three empty `data` fields | `"\n\n"` |

The WHATWG algorithm appends LF for each `data` field and removes only the final LF at dispatch. Therefore, one empty data field represents empty data, while two empty data fields represent one newline.

### 7.4 Encoding algorithm

`encode/1` MUST behave as if it performs these steps:

1. Verify that the input is a map.
2. Verify that its keys are exactly a permitted subset containing `:data`.
3. Validate the types and UTF-8 validity of every present field.
4. Reject CR/LF in `:event`.
5. Reject NULL/CR/LF in `:id`.
6. Reject a negative or non-integer `:retry`.
7. Normalize line endings in `:data`.
8. Initialize an empty iodata result.
9. If `:event` is present, append `event: VALUE\n`.
10. If `:id` is present, append `id: VALUE\n`.
11. If `:retry` is present, append `retry: DECIMAL\n`.
12. For every normalized data line, append `data: LINE\n`.
13. Append one additional LF to terminate the event.
14. Return the iodata without unnecessarily flattening it.

Validation MUST complete before any output is returned. `encode/1` has no partial-output mode.

### 7.5 Exact examples

Minimal event:

```elixir
Datastar.SSE.encode(%{data: "hello"})
```

```text
data: hello

```

Empty values:

```elixir
Datastar.SSE.encode(%{event: "", id: "", retry: 0, data: ""})
```

```text
event: 
id: 
retry: 0
data: 

```

Leading spaces and colons:

```elixir
Datastar.SSE.encode(%{event: " custom:type", data: " value: 1"})
```

```text
event:  custom:type
data:  value: 1

```

The two spaces after each colon are intentional: one is the canonical delimiter and one belongs to the value.

### 7.6 Required final blank line

An encoded event MUST end in `\n\n`. EOF does not dispatch an incomplete pending event under the WHATWG algorithm. This invariant MUST have a direct exact-byte test; a decoder round trip alone is not sufficient evidence.

## 8. WHATWG semantic model

The suite MUST test the encoder against the standard's interpretation, not merely its grammar.

### 8.1 Dispatch semantics

For browser semantics:

- each `data` field appends its value and one LF to the data buffer;
- a blank line attempts dispatch;
- no event is dispatched when the data buffer is empty because no `data` field was processed;
- immediately before dispatch, one final LF is removed from the data buffer;
- absent or empty event type dispatches as `"message"`;
- the event type and data buffers reset after dispatch;
- the last event ID persists across events until another valid `id` field changes it;
- empty `id` resets the persistent last event ID;
- `retry` containing only ASCII digits changes reconnection time;
- comments and unknown fields are ignored;
- incomplete data at EOF is discarded.

Because `Datastar.SSE.encode/1` always includes at least one `data` field and a final blank line, every accepted event MUST cause exactly one dispatch when evaluated in isolation.

### 8.2 Encoder normalization target

For an input event `e`, define `normalize(e)` as:

- the same map keys and values;
- `:data` with CRLF and CR normalized to LF;
- no other changes.

The principal field-level property is:

```text
ServerSentEvents.decode_stream([encode(e)]) == [normalize(e)]
```

The principal browser-level property is:

```text
WHATWG_interpret(encode(e)) dispatches exactly one MessageEvent
MessageEvent.data == normalize(e).data
MessageEvent.type == (e.event when non-empty, otherwise "message")
MessageEvent.lastEventId == (e.id when present, otherwise prior last event ID)
```

If `:retry` is present, the model's reconnection time MUST equal that integer after interpretation.

### 8.3 Why a test-only model is needed

The `server_sent_events` package intentionally performs field-level decoding only. It does not:

- supply the browser's default `"message"` type;
- persist last-event-ID state between events;
- apply retry values as reconnection time;
- open connections or model EventSource lifecycle.

Those are valid boundaries for that package, but they mean its decoded map cannot prove every browser-level requirement. The small WHATWG model fills that gap without becoming production code.

## 9. Role of `ServerSentEvents`

[`server_sent_events`](https://github.com/benjreinhart/server_sent_events) is a maintained, dependency-free Elixir decoder. Version 1.1.0 exposes:

- `ServerSentEvents.decode_stream/1` for an enumerable of binary chunks;
- `ServerSentEvents.Parser` for lower-level incremental parsing;
- event maps with required `:data` and optional `:event`, `:id`, and `:retry`;
- parsing across arbitrary input chunk boundaries;
- WHATWG field behavior such as ignoring comments and invalid retry values.

For this milestone it is a test-only dependency:

```elixir
defp deps do
  [
    {:server_sent_events, "~> 1.1", only: :test, runtime: false},
    {:stream_data, "~> 1.4", only: :test, runtime: false}
  ]
end
```

Its roles are:

1. **Independent interoperability check.** An implementation written for decoding, in another project, must reconstruct our intended normalized event.
2. **Incremental parser check.** The result must not depend on how transport chunks divide the encoded bytes.
3. **Shared semantic shape.** Using its event map avoids inventing a nominal `%SSE.Event{}` without demonstrated need.
4. **Upstream prototype evidence.** A working, thoroughly tested encoder can later support a focused proposal to move generic encoding into `server_sent_events`.

It MUST NOT become:

- the normative source for expected behavior;
- a production dependency merely for encoding;
- a reason to omit direct WHATWG cases;
- an oracle for UTF-8 validity, since its decoder assumes UTF-8 rather than validating malformed input;
- an oracle for persistent EventSource state.

If the encoder is later accepted upstream, `Datastar.SSE` may delegate to it or disappear behind a compatibility layer. The semantic map and conformance suite should make that change low risk.

## 10. Test-suite structure

The complete suite has six layers.

| Layer | Primary file | What it proves |
| --- | --- | --- |
| Exact examples | `sse_test.exs` | Stable canonical bytes and iodata API |
| Validation | `sse_test.exs` | Invalid or unsafe values fail explicitly |
| WHATWG semantics | `sse_whatwg_test.exs` | Browser-level interpretation and state |
| Decoder interoperability | both main test files | Independent Elixir decoder reconstructs events |
| Property tests | `sse_property_test.exs` | Invariants hold across a large generated space |
| WPT-derived regressions | `sse_whatwg_test.exs` | Known standards edge cases remain covered |

### 10.1 Exact canonical wire tests

At minimum, golden tests MUST cover:

- data-only event;
- all fields present and in canonical order;
- absent optional fields;
- empty `data`;
- empty `event`;
- empty `id`;
- `retry: 0`;
- multiline LF data;
- CRLF data normalization;
- standalone CR data normalization;
- mixed newline normalization;
- one and several trailing newlines;
- leading spaces in every binary field;
- colons in values;
- NULL in data;
- NULL in event;
- non-ASCII and multi-byte Unicode;
- no BOM at stream start;
- exactly one final blank line;
- concatenating two encoded events;
- empty, multiline, CRLF, and trailing-newline comments.

Golden tests SHOULD convert iodata with `IO.iodata_to_binary/1` and compare exact binaries.

### 10.2 Validation tests

Tests MUST reject:

- non-map input;
- missing `:data`;
- string-keyed maps;
- unknown keys;
- non-binary `:data`, `:event`, or `:id`;
- malformed UTF-8 in every binary field and in comments;
- CR, LF, and CRLF in `:event`;
- NULL, CR, LF, and CRLF in `:id`;
- negative retry;
- float retry;
- numeric string retry;
- atom, `nil`, and boolean retry.

Injection-shaped regressions MUST be explicit:

```elixir
assert_raise ArgumentError, fn ->
  Datastar.SSE.encode(%{data: "ok", event: "safe\ndata: injected"})
end

assert_raise ArgumentError, fn ->
  Datastar.SSE.encode(%{data: "ok", id: "42\n\nretry: 0"})
end
```

### 10.3 Interoperability tests

A common helper may be:

```elixir
defp decode(iodata) do
  iodata
  |> IO.iodata_to_binary()
  |> List.wrap()
  |> ServerSentEvents.decode_stream()
  |> Enum.to_list()
end
```

Representative assertion:

```elixir
test "multiline data round-trips through ServerSentEvents" do
  event = %{event: "message", id: "42", retry: 0, data: "one\r\ntwo\n"}

  expected = %{event | data: "one\ntwo\n"}

  assert decode(Datastar.SSE.encode(event)) == [expected]
end
```

Comments MUST decode to no events:

```elixir
assert decode(Datastar.SSE.encode_comment("heartbeat")) == []
```

### 10.4 Chunk-boundary tests

Encoded output must remain interpretable when delivered in arbitrary chunks. Tests MUST include:

- one complete binary;
- one byte per chunk;
- every possible single split point for several short fixtures;
- splits between `\r` and `\n` in input accepted by the independent decoder;
- splits inside multi-byte UTF-8 sequences;
- generated chunk-size patterns for property tests.

The key property is:

```text
decode([whole_binary]) == decode(arbitrary_binary_chunks)
```

Network packet boundaries and iodata nesting MUST have no semantic significance.

### 10.5 Concatenation tests

SSE is a stream. The suite MUST prove that event framing composes:

```elixir
encoded = [
  Datastar.SSE.encode(%{id: "1", data: "first"}),
  Datastar.SSE.encode(%{data: "second"})
]
```

The field-level decoder must produce two maps. The WHATWG model must dispatch two events and show that the second browser event inherits last event ID `"1"`. Another test must show that `%{id: "", data: "reset"}` resets it.

## 11. WHATWG compliance suite

### 11.1 Direct requirements matrix

Every relevant standard rule MUST map to at least one named test.

| WHATWG rule | Encoder decision | Required test |
| --- | --- | --- |
| Streams are UTF-8 | accept only valid UTF-8 and emit it unchanged | Unicode success; malformed binaries rejected |
| CRLF, LF, or CR delimit physical lines | emit LF only | output contains no CR |
| optional one space after colon is removed | always emit one delimiter space | leading value spaces survive decoding |
| comments begin with colon and are ignored | emit `: VALUE\n` | comments dispatch no events |
| data fields append value plus LF | split normalized data into fields | multiline and empty-line cases |
| one final data-buffer LF is removed | preserve trailing empty components | `""`, `"\n"`, `"one\n"`, `"\n\n"` |
| blank line dispatches | append final blank line | exact `\n\n` suffix and one dispatch |
| EOF does not dispatch incomplete data | never rely on EOF | removing final LF pair prevents dispatch in model |
| empty data buffer dispatches nothing | always emit a `data` field | empty string still produces one event |
| empty event type defaults to `message` | permit empty event field | browser model reports type `message` |
| valid ID persists | encode valid IDs faithfully | concatenated-event state test |
| empty ID resets state | allow empty ID | reset state test |
| ID containing NULL is ignored | reject such input | validation test |
| retry accepts only ASCII digits | emit non-negative integer as decimal | zero and generated integer tests |
| field names are case-sensitive | emit lowercase standard names only | golden output |

### 11.2 WPT-derived regressions

The [Web Platform Tests EventSource suite](https://wpt.live/eventsource/) includes cases for BOMs, comments, data fields, empty/custom event fields, IDs, NULL IDs, retry parsing, the final empty line, leading spaces, multiple newline styles, NULL characters, and UTF-8.

`Datastar.SSE` SHOULD use that suite as an edge-case checklist, but MUST NOT copy it wholesale or claim that running encoder tests is equivalent to running browser WPT. Many WPT cases exercise malformed or non-canonical input that this encoder deliberately never emits.

For every relevant WPT category, the project SHOULD record one of:

- covered directly by an encoder test;
- covered by the test-only WHATWG model;
- impossible by construction in canonical output;
- out of scope because it concerns HTTP or EventSource lifecycle.

Suggested mapping:

| WPT category | Local treatment |
| --- | --- |
| BOM | Assert encoder never prefixes BOM; permit U+FEFF as ordinary field data |
| Comments | Encode and verify no dispatch |
| Data fields | Golden and property round trips |
| Empty event field | Verify browser default type and decoder map shape separately |
| ID and NULL ID | Persistence/reset tests; reject unrepresentable NULL ID |
| Retry valid/bogus/empty | Emit valid digits only; reject invalid API values |
| Leading space | Verify preservation after delimiter handling |
| Newline variants | Normalize semantic data; emit LF only |
| NULL character | Allow in data/event; reject in ID |
| UTF-8 | Unicode fixtures and malformed-input rejection |
| MIME, redirects, credentials, requests | Deferred to Plug/browser integration suites |

## 12. Property-based testing with StreamData

Property tests complement examples; they do not replace them. Golden tests specify exact canonical output for boundary cases. Properties search a much larger space and shrink failures to useful counterexamples.

[`ExUnitProperties`](https://stream-data.hexdocs.pm/ExUnitProperties.html) runs generated cases repeatedly and shrinks failing inputs. The default is 100 runs; CI MAY increase `max_runs` for the core round-trip properties after runtime is measured.

### 12.1 Generator design

Generators SHOULD produce valid values by construction where practical. Broad filtering can cause `StreamData.FilterTooNarrowError` and poorer shrinking.

An illustrative test-support API is:

```elixir
defmodule Datastar.SSE.Generators do
  import StreamData

  def utf8_string do
    string(:utf8)
  end

  def data do
    # Weight explicit newline-heavy fixtures so normalization and trailing
    # empty components occur much more often than random Unicode alone.
    multiline =
      bind(list_of(utf8_string()), fn lines ->
        map(member_of(["\n", "\r", "\r\n"]), fn newline ->
          Enum.join(lines, newline)
        end)
      end)

    frequency([
      {5, utf8_string()},
      {2, member_of(["", "\n", "\n\n", "\r", "\r\n", "one\n", "one\r\ntwo\r"])},
      {3, multiline}
    ])
  end

  def event_name do
    string(:utf8)
    |> filter(&(not String.contains?(&1, ["\r", "\n"])))
  end

  def id do
    string(:utf8)
    |> filter(&(not String.contains?(&1, ["\0", "\r", "\n"])))
  end

  def event do
    bind(data(), fn data ->
      optional_map(%{
        event: event_name(),
        id: id(),
        retry: non_negative_integer()
      })
      |> map(&Map.put(&1, :data, data))
    end)
  end
end
```

The snippet is a design illustration, not mandatory source code. The important generator characteristics are:

- valid UTF-8 across ASCII and non-ASCII ranges;
- all combinations of optional keys;
- empty strings;
- newline-heavy data, including trailing newlines;
- leading spaces and colons;
- zero and larger retry values;
- values that shrink cleanly.

Because CR, LF, and NULL are rare in broad Unicode generation, targeted `member_of/1` and `frequency/1` branches MUST supplement the random strings.

### 12.2 Core round-trip property

```elixir
use ExUnitProperties

property "valid events survive canonical encoding and independent decoding" do
  check all event <- Datastar.SSE.Generators.event() do
    encoded =
      event
      |> Datastar.SSE.encode()
      |> IO.iodata_to_binary()

    assert [normalize(event)] ==
             encoded
             |> List.wrap()
             |> ServerSentEvents.decode_stream()
             |> Enum.to_list()
  end
end
```

This property proves field-level interoperability. `normalize/1` MUST be test code independent of the production normalizer.

### 12.3 Canonical-output property

For every generated valid event:

- `encode/1` returns valid iodata;
- flattening it yields a valid UTF-8 binary;
- the binary contains no CR;
- the binary does not begin with a UTF-8 BOM;
- the binary ends with exactly the event terminator `\n\n`;
- decoding yields exactly one normalized event;
- re-encoding that decoded event yields the same canonical binary.

The last invariant is canonicalization stability:

```text
encode(decode(encode(e)).only_event) == encode(e)
```

### 12.4 Chunk-invariance property

Generate both a valid event and a list of positive chunk sizes. Split the flattened binary by byte count, always appending any remainder. Then assert:

```elixir
property "decoding is invariant under arbitrary transport chunking" do
  check all event <- event(),
            sizes <- list_of(positive_integer(), min_length: 1) do
    binary = event |> Datastar.SSE.encode() |> IO.iodata_to_binary()
    chunks = split_by_sizes(binary, sizes)

    assert decode([binary]) == decode(chunks)
  end
end
```

Chunking MUST be byte-oriented rather than codepoint-oriented so generated cuts can occur inside a multi-byte UTF-8 sequence. Dedicated deterministic tests SHOULD still exercise every cut point of a short Unicode fixture, because random sizes do not guarantee that boundary on every run.

### 12.5 Sequence property

Generate a non-empty list of valid events, encode them as one iodata stream, arbitrarily chunk the stream, and assert that `ServerSentEvents` returns the normalized list in order.

The WHATWG model SHOULD evaluate the same sequence to verify:

- dispatch count and order;
- default/custom browser event types;
- persistent and reset last-event-ID state;
- final reconnection time after retry fields.

### 12.6 Comment properties

For every valid UTF-8 comment:

- output is valid iodata and UTF-8;
- output contains no CR;
- every physical line starts with `: `;
- output ends in one LF but not an automatically added blank line;
- `ServerSentEvents` decodes it to no events;
- inserting it between encoded events does not change their decoded field-level events or browser dispatches.

### 12.7 Invalid-input properties

Targeted invalid generators SHOULD cover:

- malformed UTF-8 byte sequences;
- event names with inserted CR or LF;
- IDs with inserted NULL, CR, or LF;
- negative integers and non-integer retry values;
- maps missing `:data`;
- maps with an added unknown key;
- wrong value types.

Every generated invalid value MUST raise `ArgumentError`. Invalid generators should construct a known violation rather than generate arbitrary terms and filter for failure.

### 12.8 Reproducibility and runtime

- Property failures MUST print the StreamData seed so they can be reproduced.
- CI SHOULD retain the failing seed in its logs.
- Fast properties MAY use the default run count locally and a higher `max_runs` in CI.
- Large data sizes SHOULD be bounded initially to keep shrinking and CI times useful.
- Any discovered minimal counterexample MUST become a named regression test before the bug is fixed.

## 13. Quality and implementation constraints

The production implementation MUST:

- have zero runtime dependencies for this milestone;
- avoid unnecessary binary concatenation and return iodata;
- validate before serialization;
- preserve input map immutability;
- be deterministic;
- have typespecs and module/function documentation;
- keep Datastar-specific event semantics out of the module;
- keep HTTP concerns out of the module.

Performance benchmarks are optional for the first slice. Correctness and a clear API take priority. Before upstreaming, benchmarks SHOULD include large single-line data, large multiline HTML, many short data lines, and comments, measuring both reductions and allocation.

## 14. Definition of done

The first SSE milestone is complete when all of the following are true:

- [ ] `Datastar.SSE.event()` is documented and matches the specified semantic map.
- [ ] `encode/1` returns canonical iodata for all accepted events.
- [ ] `encode_comment/1` returns canonical comment iodata.
- [ ] Every validation rule has a direct negative test.
- [ ] Empty and trailing-newline data cases have exact golden tests.
- [ ] Every relevant WHATWG rule maps to a named test.
- [ ] A test-only WHATWG model verifies dispatch, ID persistence/reset, and retry state.
- [ ] `ServerSentEvents.decode_stream/1` reconstructs every generated normalized event.
- [ ] Interoperability is invariant under arbitrary byte chunking.
- [ ] StreamData properties cover individual events, sequences, comments, and invalid input.
- [ ] Relevant WPT categories are mapped to covered, impossible-by-construction, or deferred cases.
- [ ] Production code has no runtime dependency.
- [ ] The module contains no Plug, Phoenix, process, PubSub, or Datastar payload logic.
- [ ] The public module documentation states the canonicalization and error contracts.

The resulting guarantee is:

> Given any event accepted by `Datastar.SSE.event()`, `encode/1` produces valid UTF-8 `text/event-stream` syntax in one canonical form. WHATWG interpretation yields the requested normalized event and stream-state changes. The output interoperates with `server_sent_events`, is invariant under arbitrary transport chunking, preserves every representable data value, and rejects values that cannot be encoded safely or faithfully.

## 15. Deferred evolution

The following are deliberate future decisions, not blockers:

- adding a non-raising API such as `encode_event/1` returning `{:ok, iodata} | {:error, reason}`;
- introducing a struct if real invariants or protocol implementations justify nominal typing;
- supporting raw ID-only or retry-only control blocks;
- extracting a generic Plug SSE transport;
- moving the encoder into `server_sent_events` upstream;
- adding browser-driven integration tests;
- adding HTTP response and disconnect behavior;
- scheduling comment heartbeats.

Raw control blocks should not be squeezed into the current `event()` type. If a future use case needs blocks that alter ID or retry state without dispatching data, the project should introduce a separate stream-item or control-block abstraction.

## 16. References

- [WHATWG HTML Living Standard — Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
- [`server_sent_events` repository](https://github.com/benjreinhart/server_sent_events)
- [`ServerSentEvents` 1.1.0 documentation](https://server-sent-events.hexdocs.pm/)
- [Web Platform Tests — EventSource suite](https://wpt.live/eventsource/)
- [StreamData documentation](https://stream-data.hexdocs.pm/)
- [ExUnitProperties documentation](https://stream-data.hexdocs.pm/ExUnitProperties.html)
- [Datastar SDK architecture decision record](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md)
