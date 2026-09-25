defmodule Datastar do
  @moduledoc """
  An Elixir SDK for [Datastar](https://data-star.dev/), aiming to comply
  with the [Datastar SDK architecture decision
  record](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md).

  The package is named `datastar_ex`; `Datastar` is the root namespace a
  developer works with.

  Currently provided:

    * `Datastar.SSE` — a canonical, dependency-free Server-Sent Events
      encoder, the protocol foundation the Datastar event constructors
      will build on.

  Datastar event construction (`datastar-patch-elements`,
  `datastar-patch-signals`) and HTTP integration are not implemented yet.
  """
end
