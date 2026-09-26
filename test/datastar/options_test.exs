defmodule Datastar.OptionsTest do
  use ExUnit.Case, async: true
  doctest Datastar.Options

  alias Datastar.Options

  describe "validate_keys!/2" do
    test "accepts allowed unique keys" do
      assert Options.validate_keys!([event_id: "1", retry_duration: 5], [
               :event_id,
               :retry_duration
             ]) == :ok

      assert Options.validate_keys!([], [:event_id]) == :ok
    end

    test "raises on unknown option" do
      assert_raise ArgumentError, ~r/unknown option :bogus/, fn ->
        Options.validate_keys!([bogus: 1], [:event_id])
      end
    end

    test "raises on duplicate option" do
      assert_raise ArgumentError, ~r/duplicate option :event_id/, fn ->
        Options.validate_keys!([event_id: "1", event_id: "2"], [:event_id])
      end
    end

    test "raises on non-keyword input" do
      map = %{event_id: "1"}

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        # credo:disable-for-lines:1 Credo.Check.Refactor.Apply
        apply(Options, :validate_keys!, [map, [:event_id]])
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Options.validate_keys!([{"event_id", "1"}], [:event_id])
      end
    end
  end

  describe "apply_shared!/2" do
    test "absent options leave the event untouched" do
      assert Options.apply_shared!(%{event: "e", data: "d"}, []) == %{event: "e", data: "d"}
    end

    test "event_id is included whenever supplied, even empty" do
      assert Options.apply_shared!(%{data: "d"}, event_id: "42") == %{data: "d", id: "42"}
      assert Options.apply_shared!(%{data: "d"}, event_id: "") == %{data: "d", id: ""}
    end

    test "retry_duration 1000 is the default and is omitted" do
      assert Options.apply_shared!(%{data: "d"}, retry_duration: 1_000) == %{data: "d"}
    end

    test "non-default retry_duration is included, including zero" do
      assert Options.apply_shared!(%{data: "d"}, retry_duration: 2_000) == %{
               data: "d",
               retry: 2_000
             }

      assert Options.apply_shared!(%{data: "d"}, retry_duration: 0) == %{data: "d", retry: 0}
    end

    test "invalid event_id raises" do
      for bad <- [1, nil, :id, "a\nb", "a\rb", "a\0b", <<0xFF>>] do
        assert_raise ArgumentError, fn ->
          Options.apply_shared!(%{data: "d"}, event_id: bad)
        end
      end
    end

    test "invalid retry_duration raises" do
      for bad <- [-1, 1.5, "1000", nil] do
        assert_raise ArgumentError, fn ->
          Options.apply_shared!(%{data: "d"}, retry_duration: bad)
        end
      end
    end
  end
end
