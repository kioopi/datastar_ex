if Code.ensure_loaded?(Plug) do
  defmodule Datastar.Plug.Signals do
    @moduledoc """
    Reads incoming Datastar signals from a `%Plug.Conn{}` (SDK core spec
    §9.2–§9.5) — a thin effectful shell over `Datastar.Signals.Reader`,
    which owns the method-to-source rule and JSON-object decoding.

    This module only fetches bytes and enforces transport limits: the
    `datastar` query parameter for GET/DELETE, the request body for
    every other method (including Datastar's `QUERY` action). The
    updated connection is always returned, because reading a request
    body advances adapter state.

    Read signals *before* starting the SSE response (§9.6).

    This module compiles only when the optional `:plug` dependency is
    present.
    """

    alias Datastar.Options
    alias Datastar.Signals.Reader

    @default_max_length 1_000_000
    @allowed_opts [:max_length, :read_length, :decoder]
    @query_key "datastar"

    @typedoc "Stable error categories for incoming signal reading."
    @type read_error :: :invalid_json | :not_an_object | :too_large | {:read_body, term()}

    @doc """
    Reads and decodes the request's signals.

    Options: `:max_length` (total byte limit, default `1_000_000`),
    `:read_length` (bytes per body read, default `1_000_000`), and
    `:decoder` (a `(binary -> {:ok, term} | {:error, term})` function,
    default the standard-library `JSON.decode/1`).

    A missing `datastar` query key or an empty body is an empty signal
    map. `datastar=` (present but empty) is `:invalid_json`.
    """
    @spec read_signals(Plug.Conn.t(), keyword()) ::
            {:ok, map(), Plug.Conn.t()} | {:error, read_error(), Plug.Conn.t()}
    def read_signals(conn, opts \\ []) do
      Options.validate_keys!(opts, @allowed_opts)
      max_length = validate_length!(opts, :max_length, @default_max_length)
      read_length = validate_length!(opts, :read_length, @default_max_length)
      decoder_opts = Keyword.take(opts, [:decoder])

      case Reader.source(conn.method) do
        :query -> read_query(conn, max_length, decoder_opts)
        :body -> read_body_signals(conn, max_length, read_length, decoder_opts)
      end
    end

    defp validate_length!(opts, key, default) do
      case Keyword.get(opts, key, default) do
        length when is_integer(length) and length > 0 ->
          length

        other ->
          raise ArgumentError,
                "#{inspect(key)} must be a positive integer, got: #{inspect(other, limit: 5)}"
      end
    end

    defp read_query(conn, max_length, decoder_opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{@query_key => raw} when byte_size(raw) > max_length ->
          {:error, :too_large, conn}

        %{@query_key => raw} when is_binary(raw) ->
          decode(raw, decoder_opts, conn)

        %{@query_key => _non_binary} ->
          {:error, :not_an_object, conn}

        _missing ->
          {:ok, %{}, conn}
      end
    end

    defp read_body_signals(conn, max_length, read_length, decoder_opts) do
      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          read_raw_body(conn, max_length, read_length, decoder_opts, [])

        %{"_json" => _wrapped} ->
          # Plug.Parsers encodes non-object JSON bodies under "_json".
          {:error, :not_an_object, conn}

        %{} = params ->
          {:ok, params, conn}
      end
    end

    defp read_raw_body(conn, max_length, read_length, decoder_opts, acc) do
      case Plug.Conn.read_body(conn, length: read_length) do
        {:ok, chunk, conn} ->
          finish_body([chunk | acc], max_length, decoder_opts, conn)

        {:more, chunk, conn} ->
          acc = [chunk | acc]

          if IO.iodata_length(acc) > max_length do
            {:error, :too_large, conn}
          else
            read_raw_body(conn, max_length, read_length, decoder_opts, acc)
          end

        {:error, reason} ->
          {:error, {:read_body, reason}, conn}
      end
    end

    defp finish_body(acc, max_length, decoder_opts, conn) do
      if IO.iodata_length(acc) > max_length do
        {:error, :too_large, conn}
      else
        case acc |> Enum.reverse() |> IO.iodata_to_binary() do
          "" -> {:ok, %{}, conn}
          body -> decode(body, decoder_opts, conn)
        end
      end
    end

    defp decode(raw, decoder_opts, conn) do
      case Reader.decode(raw, decoder_opts) do
        {:ok, signals} -> {:ok, signals, conn}
        {:error, reason} -> {:error, reason, conn}
      end
    end
  end
end
