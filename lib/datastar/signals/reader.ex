defmodule Datastar.Signals.Reader do
  @moduledoc """
  Pure HTTP decision core for reading incoming Datastar signals
  (SDK core spec §9.1).

  `source/1` decides where a request's signals live — the `datastar`
  query parameter for GET and DELETE, the request body for every other
  method (which intentionally covers Datastar's `QUERY` action).
  `decode/2` turns a raw signals binary into a signal map, requiring a
  JSON object.

  This module never touches a connection: fetching query parameters,
  reading bodies, size limits, and mapping *absent* input to an empty
  map belong to the HTTP adapter. Data errors are tagged tuples, never
  exceptions; exceptions from a caller-supplied decoder propagate
  unchanged.
  """

  alias Datastar.Options

  @typedoc "Stable categories for malformed incoming signal data."
  @type decode_error :: :invalid_json | :not_an_object

  @typedoc "A JSON decoder function returning {:ok, term} | {:error, term}."
  @type decoder :: (binary() -> {:ok, term()} | {:error, term()})

  @query_methods ["get", "delete"]

  @doc """
  Returns where a request with the given HTTP method carries its signals.

  ## Examples

      iex> Datastar.Signals.Reader.source("GET")
      :query

      iex> Datastar.Signals.Reader.source("QUERY")
      :body

  """
  @spec source(String.t()) :: :query | :body
  def source(method) when is_binary(method) do
    if String.downcase(method) in @query_methods, do: :query, else: :body
  end

  def source(other) do
    raise ArgumentError, "method must be a binary, got: #{inspect(other, limit: 5)}"
  end

  @doc """
  Decodes a raw signals binary into a signal map.

  Uses the standard-library `JSON.decode/1` unless a `:decoder` option
  supplies a `(binary -> {:ok, term} | {:error, term})` function.
  Undecodable input — including the empty binary — is
  `{:error, :invalid_json}`; a decoded array, scalar, null, or struct is
  `{:error, :not_an_object}`.

  ## Examples

      iex> Datastar.Signals.Reader.decode(~s({"count":2}))
      {:ok, %{"count" => 2}}

      iex> Datastar.Signals.Reader.decode("")
      {:error, :invalid_json}

      iex> Datastar.Signals.Reader.decode("[1,2]")
      {:error, :not_an_object}

  """
  @spec decode(binary(), [{:decoder, decoder()}]) :: {:ok, map()} | {:error, decode_error()}
  def decode(json, opts \\ [])

  def decode(json, opts) when is_binary(json) do
    opts = Options.validate!(opts, decoder: &JSON.decode/1)
    decoder = Keyword.fetch!(opts, :decoder)

    unless is_function(decoder, 1) do
      raise ArgumentError,
            ":decoder must be a one-arity function, got: #{inspect(decoder, limit: 5)}"
    end

    case decoder.(json) do
      {:ok, object} when is_map(object) and not is_struct(object) ->
        {:ok, object}

      {:ok, _other} ->
        {:error, :not_an_object}

      {:error, _reason} ->
        {:error, :invalid_json}

      other ->
        raise ArgumentError,
              "decoder returned #{inspect(other, limit: 5)}, expected {:ok, term} | {:error, term}"
    end
  end

  def decode(other, _opts) do
    raise ArgumentError, "signals input must be a binary, got: #{inspect(other, limit: 5)}"
  end
end
