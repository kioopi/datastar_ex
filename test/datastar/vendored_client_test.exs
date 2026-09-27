defmodule Datastar.VendoredClientTest do
  use ExUnit.Case, async: true

  @bundle Path.join(__DIR__, "../support/browser/assets/datastar.js")
  # v1.0.4 bundles/datastar.js — must match PROVENANCE.md.
  @sha256 "727844adfc825ee651fb93c544a2a739986f9a21820a94524b35f0cac470cf91"

  test "the vendored Datastar client is byte-identical to the pinned v1.0.4 bundle" do
    hash =
      @bundle
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert hash == @sha256
  end
end
