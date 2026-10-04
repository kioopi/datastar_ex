defmodule Datastar do
  @moduledoc """
  An Elixir SDK for [Datastar](https://data-star.dev/), aiming to comply
  with the [Datastar SDK architecture decision
  record](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md).

  The package is named `datastar_ex`; `Datastar` is the root namespace a
  developer works with.

  ## Primary public surface (§4.6)

  The functions below form the main entry point to the library:

    * `patch_elements/1,2` — constructs a `datastar-patch-elements` event
    * `remove_elements/1,2` — removes elements by selector
    * `patch_signals/1,2` — constructs a `datastar-patch-signals` event from a map
    * `patch_signals_raw/1,2` — constructs a `datastar-patch-signals` event from raw JSON
    * `execute_script/1,2` — constructs a script-executing element patch
    * `redirect/1,2` — constructs the canonical client-side redirect
    * `decode/1` — reads a parsed SSE event back into a Datastar event

  Each is a thin facade over the module below that implements it.

  ## Examples

      iex> Datastar.patch_elements("<li>New</li>", selector: "#feed", mode: :append)
      ...> |> Datastar.SSE.encode()
      ...> |> IO.iodata_to_binary()
      "event: datastar-patch-elements\\ndata: selector #feed\\ndata: mode append\\ndata: elements <li>New</li>\\n\\n"

  ## Currently provided

    * `Datastar.SSE` — a canonical, dependency-free Server-Sent Events
      encoder, the protocol foundation the Datastar event constructors
      will build on.
    * `Datastar.Elements` — constructs element-patching and removal events
    * `Datastar.Signals` — constructs signal-patching events from maps or raw JSON
    * `Datastar.Signals.Reader` — reads Datastar signal streams from an HTTP response
    * `Datastar.Script` — constructs script-executing element patches
    * `Datastar.Plug` — sends the constructed events as SSE over a
      `%Plug.Conn{}` (compiles only when the optional `:plug` dependency
      is present)
    * `Datastar.Plug.Signals` — reads incoming Datastar signals from a
      `%Plug.Conn{}` (same optional dependency)
    * `Datastar.Decode` — reads Datastar events back out of parsed SSE events
    * `Datastar.Attribute` — pure constructors for the client-side
      `data-*` attributes, returned as `{name, value}` tuples
    * `Datastar.Plug.ReadSignals` — a plug that reads incoming signals
      and assigns them (optional `:plug` dependency)
    * `Datastar.Plug.Test` — a closed-connection conn for testing a
      consumer's disconnect branch (same optional dependency)
    * `Datastar.Plug.Stream` — a read-side SSE stream loop over
      `Datastar.Plug`'s primitives (same optional dependency)

  `Datastar.Plug.Stream` owns the read-side loop — subscribe, snapshot,
  heartbeat, and detecting the disconnect — over those same primitives.

  ## Compatibility

  This SDK targets Datastar v1.0.4 and requires Elixir >= 1.18, since the
  core encodes and decodes JSON with the standard-library `JSON` module
  rather than a third-party dependency.
  """

  @doc "Constructs a `datastar-patch-elements` event. See `Datastar.Elements.patch/2`."
  defdelegate patch_elements(elements, opts \\ []), to: Datastar.Elements, as: :patch

  @doc "Removes elements by selector. See `Datastar.Elements.remove/2`."
  defdelegate remove_elements(selector, opts \\ []), to: Datastar.Elements, as: :remove

  @doc "Constructs a `datastar-patch-signals` event from a map. See `Datastar.Signals.patch/2`."
  defdelegate patch_signals(signals, opts \\ []), to: Datastar.Signals, as: :patch

  @doc "Constructs a `datastar-patch-signals` event from raw JSON. See `Datastar.Signals.patch_raw/2`."
  defdelegate patch_signals_raw(json, opts \\ []), to: Datastar.Signals, as: :patch_raw

  @doc "Constructs a script-executing element patch. See `Datastar.Script.execute/2`."
  defdelegate execute_script(script, opts \\ []), to: Datastar.Script, as: :execute

  @doc """
  Constructs the canonical Datastar redirect: a script event that
  assigns `url` to `window.location`.

  The URL is JSON-encoded, which produces a valid double-quoted
  JavaScript string literal with quotes, backslashes and control
  characters escaped. That is the point of this function: building
  `"window.location = '\#{url}'"` by hand injects into a `<script>` the
  library itself generated as soon as a URL contains a single quote,
  which a slug easily does.

  `Datastar.Script.execute/2` then neutralizes `</script` inside the
  source, so the breakout sequence is covered too.

  Options are those of `Datastar.Script.execute/2`.

  ## Examples

      iex> Datastar.redirect("/").data
      ~s{selector body\\nmode append\\nelements <script data-effect="el.remove()">window.location = "/"</script>}

  """
  @spec redirect(String.t(), [Datastar.Script.execute_option()]) :: Datastar.SSE.event()
  def redirect(url, opts \\ []) do
    url = Datastar.Validate.utf8!(url)
    Datastar.Script.execute("window.location = " <> JSON.encode!(url), opts)
  end

  @doc "Decodes a parsed SSE event into a semantic Datastar event. See `Datastar.Decode.event/1`."
  defdelegate decode(event), to: Datastar.Decode, as: :event
end
