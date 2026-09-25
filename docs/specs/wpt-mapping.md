# WPT EventSource category mapping

Per spec §11.2: each relevant Web Platform Tests EventSource category is
covered directly, covered by the test-only WHATWG model, impossible by
construction in canonical output, or deferred as out of scope.

| WPT category | Treatment | Where |
| --- | --- | --- |
| BOM | Covered: encoder never emits a leading BOM; U+FEFF valid mid-value | `sse_test.exs` "output never starts with a BOM", "U+FEFF inside a value" |
| Comments | Covered: encode + no dispatch | `sse_test.exs` comment goldens; `sse_interop_test.exs` "comments decode to no events"; `sse_whatwg_test.exs` "comments dispatch nothing" |
| Data fields | Covered | golden §7.3 tests in `sse_test.exs`; round trips in `sse_interop_test.exs`; properties |
| Empty event field | Covered | `sse_whatwg_test.exs` "empty event field dispatches as type message"; oracle characterization in `sse_interop_test.exs` |
| ID and NULL ID | Covered | persistence/reset in `sse_whatwg_test.exs`; NULL-ID rejection in `sse_test.exs` |
| Retry valid/bogus/empty | Covered / impossible: encoder emits only ASCII digits; bogus retry unrepresentable | `sse_test.exs` retry goldens + validation; `sse_whatwg_test.exs` retry state |
| Leading space | Covered | `sse_test.exs` "leading spaces and colons"; `sse_whatwg_test.exs` "leading value spaces survive" |
| Newline variants | Covered / impossible: output is LF-only; input CR/CRLF normalized | normalization goldens; canonical-output property (`no CR`) |
| NULL character | Covered | `sse_test.exs` NULL-in-data/event golden; NULL-in-id rejection |
| Field name without colon | Impossible by construction: encoder always emits `name: value` lines | canonical goldens |
| UTF-8 | Covered | unicode goldens; malformed-UTF-8 rejection; `String.valid?/1` property |
| MIME, redirects, credentials, requests | Deferred: HTTP/EventSource lifecycle, out of scope (spec §3.2) | — |
