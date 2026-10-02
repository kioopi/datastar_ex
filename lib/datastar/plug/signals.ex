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
    @allowed_opts [
      :decoder,
      max_length: @default_max_length,
      read_length: @default_max_length
    ]
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
      opts = Options.validate!(opts, @allowed_opts)

      read_opts = %{
        max_length: Options.fetch_pos_integer!(opts, :max_length),
        read_length: Options.fetch_pos_integer!(opts, :read_length),
        decoder_opts: Keyword.take(opts, [:decoder])
      }

      case Reader.source(conn.method) do
        :query -> read_query(conn, read_opts)
        :body -> read_body_signals(conn, read_opts)
      end
    end

    defp read_query(conn, read_opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{@query_key => raw} when byte_size(raw) > read_opts.max_length ->
          {:error, :too_large, conn}

        %{@query_key => raw} when is_binary(raw) ->
          decode(raw, read_opts, conn)

        %{@query_key => _non_binary} ->
          {:error, :not_an_object, conn}

        _missing ->
          {:ok, %{}, conn}
      end
    end

    defp read_body_signals(conn, read_opts) do
      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          read_raw_body(conn, read_opts, [], 0)

        %{"_json" => _wrapped} ->
          # Plug.Parsers encodes non-object JSON bodies under "_json".
          {:error, :not_an_object, conn}

        %{} = params ->
          {:ok, params, conn}
      end
    end

    # `size` is the running byte count of `acc`, so the limit check never
    # re-measures the body read so far.
    defp read_raw_body(conn, read_opts, acc, size) do
      case Plug.Conn.read_body(conn, length: read_opts.read_length) do
        {:error, reason} ->
          {:error, {:read_body, reason}, conn}

        {status, chunk, conn} ->
          acc = [acc, chunk]
          size = size + byte_size(chunk)

          cond do
            size > read_opts.max_length -> {:error, :too_large, conn}
            status == :more -> read_raw_body(conn, read_opts, acc, size)
            size == 0 -> {:ok, %{}, conn}
            true -> decode(IO.iodata_to_binary(acc), read_opts, conn)
          end
      end
    end

    defp decode(raw, read_opts, conn) do
      case Reader.decode(raw, read_opts.decoder_opts) do
        {:ok, signals} -> {:ok, signals, conn}
        {:error, reason} -> {:error, reason, conn}
      end
    end
  end
end
