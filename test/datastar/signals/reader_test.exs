defmodule Datastar.Signals.ReaderTest do
  use ExUnit.Case, async: true

  alias Datastar.Signals.Reader

  doctest Datastar.Signals.Reader

  describe "source/1 (§9.3)" do
    test "GET and DELETE read from the query, case-insensitively" do
      for method <- ["GET", "get", "Get", "DELETE", "delete"] do
        assert Reader.source(method) == :query
      end
    end

    test "every other method reads from the body, including QUERY" do
      for method <- ["POST", "PUT", "PATCH", "QUERY", "query", "OPTIONS", "anything"] do
        assert Reader.source(method) == :body
      end
    end

    test "non-binary methods raise" do
      for bad <- [:get, nil, 1, ~c"GET"] do
        assert_raise ArgumentError, ~r/method must be a binary/, fn -> Reader.source(bad) end
      end
    end
  end

  describe "decode/2 success and data errors" do
    test "a JSON object decodes to a map" do
      assert Reader.decode(~s({"a":{"b":[1,null]}})) == {:ok, %{"a" => %{"b" => [1, nil]}}}
    end

    test "undecodable input is :invalid_json, including the empty binary" do
      for bad <- ["", "{", "not json", ~s({"a":}), "\xFF"] do
        assert Reader.decode(bad) == {:error, :invalid_json}
      end
    end

    test "decoded non-objects are :not_an_object" do
      for bad <- ["[1,2]", ~s("str"), "42", "true", "null"] do
        assert Reader.decode(bad) == {:error, :not_an_object}
      end
    end

    test "a decoder returning a struct is :not_an_object" do
      decoder = fn _ -> {:ok, ~D[2026-09-26]} end
      assert Reader.decode("{}", decoder: decoder) == {:error, :not_an_object}
    end
  end

  describe "decode/2 decoder contract (§9.1)" do
    test "a caller-supplied decoder replaces the default" do
      decoder = fn json -> {:ok, %{"echo" => json}} end
      assert Reader.decode("raw", decoder: decoder) == {:ok, %{"echo" => "raw"}}
    end

    test "a well-shaped decoder error maps to :invalid_json" do
      assert Reader.decode("{}", decoder: fn _ -> {:error, %RuntimeError{}} end) ==
               {:error, :invalid_json}
    end

    test "programmer errors raise ArgumentError" do
      assert_raise ArgumentError, ~r/binary/, fn -> Reader.decode(:not_binary) end
      assert_raise ArgumentError, ~r/unknown option/, fn -> Reader.decode("{}", decode: & &1) end

      assert_raise ArgumentError, ~r/duplicate option/, fn ->
        Reader.decode("{}", [{:decoder, &JSON.decode/1}, {:decoder, &JSON.decode/1}])
      end

      assert_raise ArgumentError, ~r/one-arity/, fn ->
        Reader.decode("{}", decoder: fn _a, _b -> :nope end)
      end

      assert_raise ArgumentError, ~r/decoder returned/, fn ->
        Reader.decode("{}", decoder: fn _ -> :bare_atom end)
      end
    end

    test "exceptions from caller decoder code propagate unchanged" do
      assert_raise RuntimeError, "boom", fn ->
        Reader.decode("{}", decoder: fn _ -> raise "boom" end)
      end
    end
  end
end
