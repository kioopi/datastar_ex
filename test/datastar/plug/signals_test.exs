defmodule Datastar.Plug.SignalsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Datastar.Plug.Signals

  describe "query methods (§9.4)" do
    test "GET reads the datastar query parameter" do
      conn = conn(:get, "/?datastar=" <> URI.encode_www_form(~s({"count":1})))

      assert {:ok, %{"count" => 1}, %Plug.Conn{}} = Signals.read_signals(conn)
    end

    test "DELETE reads the query; case-insensitive method" do
      raw = URI.encode_www_form(~s({"x":true}))

      for method <- [:delete, "DELETE", "delete"] do
        conn = conn(method, "/?datastar=" <> raw)
        assert {:ok, %{"x" => true}, _conn} = Signals.read_signals(conn)
      end
    end

    test "missing datastar key is an empty map; explicit empty value is :invalid_json" do
      assert {:ok, %{}, _} = Signals.read_signals(conn(:get, "/"))
      assert {:ok, %{}, _} = Signals.read_signals(conn(:get, "/?other=1"))
      assert {:error, :invalid_json, _} = Signals.read_signals(conn(:get, "/?datastar="))
    end

    test "URL decoding is applied before JSON decoding" do
      conn = conn(:get, "/?datastar=%7B%22a%20b%22%3A%22c%26d%22%7D")
      assert {:ok, %{"a b" => "c&d"}, _} = Signals.read_signals(conn)
    end

    # Review Focus 1: repeated keys — last value wins, no crash.
    test "a repeated datastar key uses the last value" do
      first = URI.encode_www_form(~s({"n":1}))
      last = URI.encode_www_form(~s({"n":2}))
      conn = conn(:get, "/?datastar=#{first}&datastar=#{last}")

      assert {:ok, %{"n" => 2}, _} = Signals.read_signals(conn)
    end

    test "query values over :max_length are :too_large before decoding" do
      raw = URI.encode_www_form(JSON.encode!(%{"k" => String.duplicate("v", 50)}))
      conn = conn(:get, "/?datastar=" <> raw)

      assert {:error, :too_large, _} = Signals.read_signals(conn, max_length: 10)
    end

    test "non-object query JSON is rejected" do
      for raw <- ["[1,2]", ~s("s"), "42", "null"] do
        conn = conn(:get, "/?datastar=" <> URI.encode_www_form(raw))
        assert {:error, :not_an_object, _} = Signals.read_signals(conn)
      end
    end
  end

  describe "body methods (§9.5)" do
    test "POST, PUT, PATCH, and QUERY read the JSON body" do
      for method <- ["POST", "PUT", "PATCH", "QUERY"] do
        conn = conn(method, "/", ~s({"m":"#{method}"}))
        assert {:ok, %{"m" => ^method}, _} = Signals.read_signals(conn)
      end
    end

    test "already parsed object body params are used without re-reading" do
      conn = %{conn(:post, "/") | body_params: %{"pre" => "parsed"}}
      assert {:ok, %{"pre" => "parsed"}, _} = Signals.read_signals(conn)
    end

    # Review Focus 2: Plug.Parsers' array wrapper is not an object.
    test "pre-parsed _json array wrapper is :not_an_object" do
      conn = %{conn(:post, "/") | body_params: %{"_json" => [1, 2]}}
      assert {:error, :not_an_object, _} = Signals.read_signals(conn)
    end

    test "several {:more, ...} segments accumulate" do
      body = JSON.encode!(%{"long" => String.duplicate("x", 64)})
      conn = conn(:post, "/", body)

      assert {:ok, %{"long" => _}, _} = Signals.read_signals(conn, read_length: 8)
    end

    test "exact-limit passes; limit-plus-one is :too_large" do
      body = JSON.encode!(%{"k" => "v"})
      exact = byte_size(body)

      assert {:ok, %{"k" => "v"}, _} =
               Signals.read_signals(conn(:post, "/", body), max_length: exact, read_length: 4)

      assert {:error, :too_large, _} =
               Signals.read_signals(conn(:post, "/", body), max_length: exact - 1, read_length: 4)
    end

    test "empty body is an empty map; malformed JSON and non-objects are tagged" do
      assert {:ok, %{}, _} = Signals.read_signals(conn(:post, "/", ""))
      assert {:error, :invalid_json, _} = Signals.read_signals(conn(:post, "/", "{nope"))
      assert {:error, :not_an_object, _} = Signals.read_signals(conn(:post, "/", "[1]"))
    end

    test "adapter read errors are wrapped as {:read_body, reason}" do
      conn = :post |> conn("/", "{}") |> Datastar.TestSupport.ErrorBodyAdapter.wrap()

      assert {:error, {:read_body, :timeout}, _} = Signals.read_signals(conn)
    end
  end

  describe "options and threading" do
    test "a caller-supplied decoder is forwarded to the reader" do
      decoder = fn _raw -> {:ok, %{"decoded" => "custom"}} end
      conn = conn(:post, "/", "anything")

      assert {:ok, %{"decoded" => "custom"}, _} =
               Signals.read_signals(conn, decoder: decoder)
    end

    test "unknown and invalid options raise" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Signals.read_signals(conn(:get, "/"), limit: 1)
      end

      assert_raise ArgumentError, ~r/:max_length/, fn ->
        Signals.read_signals(conn(:get, "/"), max_length: 0)
      end
    end

    test "the returned connection threads through every result shape" do
      {:ok, _, %Plug.Conn{} = c1} = Signals.read_signals(conn(:get, "/"))
      {:error, :invalid_json, %Plug.Conn{} = c2} = Signals.read_signals(conn(:get, "/?datastar="))
      {:ok, _, %Plug.Conn{} = c3} = Signals.read_signals(conn(:post, "/", "{}"))
      assert c1.query_params != %Plug.Conn.Unfetched{aspect: :query_params}
      assert %Plug.Conn{} = c2
      assert %Plug.Conn{} = c3
    end

    test "reading works before an SSE response is started, then the response can start" do
      conn = conn(:post, "/", ~s({"go":true}))
      {:ok, %{"go" => true}, conn} = Signals.read_signals(conn)

      assert Datastar.Plug.start(conn).state == :chunked
    end
  end
end
