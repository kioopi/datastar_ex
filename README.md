# DatastarEx

A low-level, zero-runtime-dependency [Datastar](https://data-star.dev/) SDK
core for Elixir: an SSE encoder and pure event constructors for
`datastar-patch-elements` and `datastar-patch-signals` events. It targets
Datastar v1.0.4 and requires Elixir >= 1.18, since the core encodes and
decodes JSON with the standard-library `JSON` module.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `datastar_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:datastar_ex, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/datastar_ex>.

