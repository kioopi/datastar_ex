defmodule Datastar.AttributePluginsTest do
  use ExUnit.Case, async: true

  @bundle Path.join(__DIR__, "../support/browser/assets/datastar.js")

  # The bundle is SHA-256 pinned by Datastar.VendoredClientTest, so this is a
  # check against the real v1.0.4 client, not against documentation.
  #
  # The minified bundle writes `data-` once, as `j = e => `data-${e}``,
  # registers attribute plugins through `m({name: ...})` and actions through
  # `I({name: ...})`. Re-derive the lists with:
  #
  #   grep -oE 'm\(\{name:"[a-zA-Z-]+"' <bundle> | sed 's/.*name:"//;s/"//' | sort -u
  #   grep -oE 'j\("[a-zA-Z-]+"\)'      <bundle> | sed 's/j("//;s/")//'   | sort -u
  #
  # Asserting the registration form (not a bare quoted name) matters: the
  # string "ignore" appears in the bundle for reasons unrelated to plugins.
  setup_all do
    {:ok, bundle: File.read!(@bundle)}
  end

  test "every pinned plugin is registered as a plugin in the pinned bundle", %{bundle: bundle} do
    for plugin <- Datastar.Attribute.plugins() do
      assert String.contains?(bundle, ~s|m({name:"#{plugin}"|),
             "plugin #{inspect(plugin)} is not registered in the pinned v1.0.4 bundle"
    end
  end

  test "every bare attribute is registered as a bare data- attribute in the bundle", %{
    bundle: bundle
  } do
    for attr <- Datastar.Attribute.bare_attributes() do
      assert String.contains?(bundle, ~s|j("#{attr}")|),
             "bare attribute #{inspect(attr)} is not registered in the pinned v1.0.4 bundle"
    end
  end

  test "the pinned lists are the expected size and disjoint" do
    assert Enum.count(Datastar.Attribute.plugins()) == 17
    assert Enum.count(Datastar.Attribute.bare_attributes()) == 4

    assert Datastar.Attribute.plugins() -- Datastar.Attribute.bare_attributes() ==
             Datastar.Attribute.plugins()
  end
end
