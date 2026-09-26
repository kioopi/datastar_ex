defmodule Datastar do
  @moduledoc """
  An Elixir SDK for [Datastar](https://data-star.dev/), aiming to comply
  with the [Datastar SDK architecture decision
  record](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md).

  The package is named `datastar_ex`; `Datastar` is the root namespace a
  developer works with.

  ## Primary public surface (§4.6)

  The five functions below form the main entry point to the library:

    * `patch_elements/1,2` — constructs a `datastar-patch-elements` event
    * `remove_elements/1,2` — removes elements by selector
    * `patch_signals/1,2` — constructs a `datastar-patch-signals` event from a map
    * `patch_signals_raw/1,2` — constructs a `datastar-patch-signals` event from raw JSON
    * `execute_script/1,2` — constructs a script-executing element patch

  Each is a facade that delegates to the corresponding constructor module below.

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

  HTTP integration and signal store subscriptions are not implemented yet.
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
end
