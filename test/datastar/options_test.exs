defmodule Datastar.OptionsTest do
  use ExUnit.Case, async: true
  doctest Datastar.Options

  alias Datastar.Options

  describe "validate!/2" do
    test "accepts allowed unique keys" do
      valid = [event_id: "1", retry_duration: 5]

      assert Options.validate!(valid, [
               :event_id,
               :retry_duration
             ]) == valid

      assert Options.validate!([], [:event_id]) == []
    end

    test "raises on unknown option without echoing option values" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([event_id: "secret", bogus: 1], [:event_id])
        end

      assert Exception.message(error) == "unknown option :bogus"
    end

    test "raises on duplicate option without echoing option values" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([event_id: "secret", event_id: "2"], [:event_id])
        end

      assert Exception.message(error) == "duplicate option :event_id"
    end

    test "raises on non-keyword input" do
      map = %{event_id: "1"}

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        # credo:disable-for-lines:1 Credo.Check.Refactor.Apply
        apply(Options, :validate!, [map, [:event_id]])
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Options.validate!([{"event_id", "1"}], [:event_id])
      end
    end
  end

  describe "fetch_boolean!/2" do
    test "returns a boolean option and rejects anything else" do
      assert Options.fetch_boolean!([auto_remove: false], :auto_remove) == false

      assert_raise ArgumentError, ":auto_remove must be a boolean, got: \"yes\"", fn ->
        Options.fetch_boolean!([auto_remove: "yes"], :auto_remove)
      end
    end
  end

  describe "fetch_pos_integer!/2" do
    test "returns a positive integer option and rejects anything else" do
      assert Options.fetch_pos_integer!([max_length: 10], :max_length) == 10

      for bad <- [0, -1, 1.5, "10"] do
        assert_raise ArgumentError, ~r/^:max_length must be a positive integer, got: /, fn ->
          Options.fetch_pos_integer!([max_length: bad], :max_length)
        end
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
