defmodule Datastar.Conformance.RouterNonceTest do
  @moduledoc """
  Covers `/healthz`'s `CONFORMANCE_NONCE` override (see `scripts/conformance`
  I1(b)): the readiness probe used by the conformance scripts confirms it is
  talking to *this* run's server by comparing against a per-run nonce, not
  the fixed `"ok"` string. Mutates process-global env, so this runs
  non-async, isolated from `RouterTest`'s `async: true` module.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Datastar.Conformance.Router

  @opts Router.init([])

  test "/healthz echoes CONFORMANCE_NONCE when set" do
    System.put_env("CONFORMANCE_NONCE", "conformance-1234-5678")
    on_exit(fn -> System.delete_env("CONFORMANCE_NONCE") end)

    conn = Router.call(conn(:get, "/healthz"), @opts)

    assert conn.resp_body == "conformance-1234-5678"
  end
end
