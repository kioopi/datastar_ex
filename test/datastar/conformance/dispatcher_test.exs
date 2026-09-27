defmodule Datastar.Conformance.DispatcherTest do
  use ExUnit.Case, async: true

  alias Datastar.Conformance.Dispatcher

  test "the §11.3 patchElements description maps to the core constructor" do
    description = %{
      "type" => "patchElements",
      "elements" => "<div>Merge</div>",
      "selector" => "div",
      "mode" => "append",
      "useViewTransition" => true,
      "viewTransitionSelector" => "#main",
      "namespace" => "html",
      "eventId" => "event1",
      "retryDuration" => 2000
    }

    assert Dispatcher.events(%{"events" => [description]}) ==
             {:ok,
              [
                Datastar.Elements.patch(
                  "<div>Merge</div>",
                  selector: "div",
                  mode: :append,
                  use_view_transition: true,
                  view_transition_selector: "#main",
                  namespace: :html,
                  event_id: "event1",
                  retry_duration: 2000
                )
              ]}
  end

  test "patchSignals encodes ordinary signals canonically; signals-raw wins verbatim" do
    assert Dispatcher.events(%{
             "events" => [
               %{
                 "type" => "patchSignals",
                 "signals" => %{"b" => 2, "a" => 1},
                 "onlyIfMissing" => true
               }
             ]
           }) ==
             {:ok, [Datastar.Signals.patch_raw(~s({"a":1,"b":2}), only_if_missing: true)]}

    assert Dispatcher.events(%{
             "events" => [
               %{
                 "type" => "patchSignals",
                 "signals" => %{"x" => 1},
                 "signals-raw" => "{\n\"one\": 1\n}"
               }
             ]
           }) == {:ok, [Datastar.Signals.patch_raw("{\n\"one\": 1\n}")]}
  end

  test "executeScript maps attributes and autoRemove" do
    assert Dispatcher.events(%{
             "events" => [
               %{
                 "type" => "executeScript",
                 "script" => "console.log('hello');",
                 "attributes" => %{"type" => "text/javascript"},
                 "autoRemove" => false,
                 "eventId" => "event1",
                 "retryDuration" => 2000
               }
             ]
           }) ==
             {:ok,
              [
                Datastar.Script.execute("console.log('hello');",
                  attributes: %{"type" => "text/javascript"},
                  auto_remove: false,
                  event_id: "event1",
                  retry_duration: 2000
                )
              ]}
  end

  test "element removal fixtures build without elements" do
    assert Dispatcher.events(%{
             "events" => [%{"type" => "patchElements", "mode" => "remove", "selector" => "#x"}]
           }) == {:ok, [Datastar.Elements.remove("#x")]}
  end

  test "several descriptions preserve order" do
    {:ok, [first, second]} =
      Dispatcher.events(%{
        "events" => [
          %{"type" => "patchElements", "elements" => "<i>1</i>"},
          %{"type" => "patchSignals", "signals" => %{"n" => 2}}
        ]
      })

    assert first.event == "datastar-patch-elements"
    assert second.event == "datastar-patch-signals"
  end

  test "unknown types, missing type, and unknown enums are errors, not raises" do
    assert {:error, _} = Dispatcher.events(%{"events" => [%{"type" => "mergeFragments"}]})
    assert {:error, _} = Dispatcher.events(%{"events" => [%{"elements" => "<i>x</i>"}]})

    assert {:error, _} =
             Dispatcher.events(%{
               "events" => [%{"type" => "patchElements", "elements" => "x", "mode" => "merge"}]
             })

    assert {:error, _} = Dispatcher.events(%{"nope" => true})
  end

  # Review Focus 3: JSON floats and negatives in retryDuration.
  test "non-integer retryDuration is an error" do
    for bad <- [2000.0, -1, "2000"] do
      assert {:error, message} =
               Dispatcher.events(%{
                 "events" => [
                   %{"type" => "patchElements", "elements" => "x", "retryDuration" => bad}
                 ]
               })

      assert message =~ "retryDuration"
    end
  end

  test "constructor-level rejections surface as errors (400-able)" do
    assert {:error, _} =
             Dispatcher.events(%{
               "events" => [
                 %{"type" => "patchElements", "elements" => "x", "selector" => "#a\nb"}
               ]
             })
  end

  test "malformed primary content fields become errors, not crashes" do
    assert {:error, _} =
             Dispatcher.events(%{
               "events" => [%{"type" => "patchElements", "elements" => 123}]
             })

    assert {:error, _} =
             Dispatcher.events(%{
               "events" => [%{"type" => "executeScript", "script" => nil}]
             })

    assert {:error, _} =
             Dispatcher.events(%{
               "events" => [%{"type" => "patchSignals", "signals-raw" => %{}}]
             })
  end

  test "patchSignals with neither signals nor signals-raw is an error" do
    assert {:error, message} = Dispatcher.events(%{"events" => [%{"type" => "patchSignals"}]})
    assert message =~ "signals"
  end

  test "explicit false booleans pass through like their defaulted absence" do
    assert Dispatcher.events(%{
             "events" => [
               %{
                 "type" => "patchElements",
                 "elements" => "<i>1</i>",
                 "useViewTransition" => false
               }
             ]
           }) == {:ok, [Datastar.Elements.patch("<i>1</i>")]}

    assert Dispatcher.events(%{
             "events" => [
               %{"type" => "patchSignals", "signals" => %{"n" => 1}, "onlyIfMissing" => false}
             ]
           }) == {:ok, [Datastar.Signals.patch_raw(~s({"n":1}))]}
  end
end
