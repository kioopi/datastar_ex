## [unreleased]

### Features

- *(sse)* Add canonical SSE event encoding to iodata
- *(sse)* Normalize CRLF and CR to LF in event data
- *(sse)* Validate events strictly before serialization
- *(sse)* Add canonical comment encoding for heartbeats
- [**breaking**] Rename root module DatastarEx to Datastar
- *(core)* Add shared event option validation and lower the Elixir floor to 1.18
- *(core)* Add internal dataline splitting and trailing-blank trimming
- *(elements)* Construct datastar-patch-elements events
- *(signals)* Construct datastar-patch-signals events from raw JSON
- *(signals)* Accept JSON-native maps via the standard-library JSON encoder
- *(signals)* Add the pure incoming-signal reader
- *(script)* Execute scripts as element patches with safe attributes
- *(api)* Add the Datastar facade over the event constructors
- *(plug)* Start chunked SSE responses with protocol-aware headers
- *(plug)* Send events and comments over chunked SSE
- *(plug)* Read incoming signals from query and body with a total size limit
- *(tooling)* Generate a committed conformance record from the official suite
- *(tooling)* Add a non-blocking upstream drift check

### Bug Fixes

- *(sse)* Give misdirected input specific bounded error messages
- *(conformance)* Thread the read conn through router error paths and batch review follow-ups
- *(tooling)* Classify a vanished upstream suite as infrastructure, not drift
- *(conformance)* Verify server identity per run and pin browser evidence honestly
- *(elements)* Reject non-keyword options in remove/2 with the standard error
- *(script)* Fold attribute names to lowercase before dedup and reservation
- *(plug)* Keep query parsing inside the documented error contract

### Performance

- *(sse)* Split data and comments in a single binary pass

### Refactor

- *(options)* Validate options with Keyword.validate/2 and defaults
- Guard non-struct maps with is_non_struct_map/1
- *(script)* Escape attribute values in a single pass
- *(signals)* Normalize lists with List.improper?/1 and Enum.map/2
- Define the shared event option type once in Datastar.Options
- *(plug)* Pass read settings as one map and count body bytes as they arrive
- Share UTF-8 and single-line value checks in Datastar.Validate
- *(sse)* Read event keys once and declare known keys up front
- *(test-support)* Share the adapter wrap helper and drop defensive lookups

### Documentation

- *(sse)* State canonicalization and error contracts
- Explain the encoder benchmark suite and its findings
- Adds the spec for SSE as reference
- Adds the spec for the Datastar SDK implementation
- V0.2 of the Datastar SDK Spec
- V0.3 of the Datastar SDK Spec
- *(spec)* Record stage 1 definition-of-done evidence
- *(spec)* Keep definition-of-done evidence out of the spec text
- Document the Plug layer and record stage 2 definition-of-done
- Record stage 3 real-server lifecycle evidence
- *(readme)* Unwrap hard-wrapped paragraphs

### Testing

- *(sse)* Prove interoperability with server_sent_events
- *(sse)* Verify browser semantics with a WHATWG model
- *(sse)* Add StreamData property suite
- *(sse)* Strengthen generators and browser-state assertions
- *(sse)* Pin review-focus cases deterministically
- *(sse)* Model id-commit timing and BOM stripping faithfully
- *(sse)* Widen invalid-event generator coverage
- *(sse)* Make U+FEFF fixtures visible as explicit bytes
- *(sse)* Document test support and fail CI on test warnings
- *(elements)* Exercise U+2028 as content, not a line break
- *(elements)* Add property suite and security regressions
- *(signals)* Add JSON-native and raw property suites
- *(script)* Add expansion, breakout, and attribute property suites
- *(core)* Pin encoded-wire bytes and state the Elixir floor outside the spec
- *(conformance)* Add deterministic sorted compact JSON for the official runner
- *(conformance)* Dispatch official fixture descriptions to the public constructors
- *(conformance)* Pin 400-ability of malformed fixture content
- *(conformance)* Serve the official /test endpoint through the public boundaries
- *(conformance)* Script the pinned official suite run
- *(conformance)* Verify server identity in the readiness probe
- *(plug)* Add a raw TCP client for real-server lifecycle tests
- *(plug)* Prove incremental delivery and clean completion on Bandit
- *(plug)* Pin disconnect, cleanup, and fragmented-read behavior on Bandit
- *(plug)* Make disconnect detection deterministic and tighten pinned reasons
- *(browser)* Vendor the pinned v1.0.4 Datastar client bundle
- *(conformance)* Generate the conformance record from golden fixtures and runner output
- *(conformance)* Pin the empty-golden-dir refusal and restore the checkout tag
- *(browser)* Run the pinned Datastar client against the SDK over headless Chrome
- *(browser)* Cover modes, namespaces, multiline, ordering, and script execution

### Build

- Adds mise and release script
- *(bench)* Add Benchee suite for the SSE encoder
- Removes obsolete vibe_kit dependency
- Sets version to 0.0.1 - The core use-case of this package is still unsupported
- *(release)* Regenerate the conformance record as part of every release

