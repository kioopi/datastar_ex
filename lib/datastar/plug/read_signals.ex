if Code.ensure_loaded?(Plug) do
  defmodule Datastar.Plug.ReadSignals do
    @moduledoc """
    A plug that reads incoming Datastar signals and assigns them.

    ```elixir
    plug Datastar.Plug.ReadSignals
    # -> conn.assigns.datastar_signals
    ```

    It is `Datastar.Plug.Signals.read_signals!/2` in plug form: a
    declarative alternative for routers that want the read in the
    pipeline rather than in every handler. It raises the same
    `Datastar.Plug.Signals.Error` on malformed input, so there is one
    error path — and one status, `400` through `Plug.Exception` — whichever
    style a router uses. Raising rather than halting lets
    `Plug.ErrorHandler` or `Plug.Debugger` render the response, as
    `Plug.Parsers` does for a malformed body.

    Options are those of `Datastar.Plug.Signals.read_signals/2`:
    `:max_length`, `:read_length` and `:decoder`. They are validated at
    `init/1` but no defaults are supplied here; absent keys stay absent
    and `read_signals/2` applies its own defaults in one place.

    A plug pipeline satisfies the ordering constraint (§9.6) by
    construction. Signals are read before the handler runs, so before it
    calls `Datastar.Plug.start/2`; malformed input can therefore still
    receive a plain 400 instead of arriving after the response is
    already chunked. The connection returned by the read is the one
    passed on, so the body is consumed exactly once.

    This module is its own plug rather than a `call/2` on
    `Datastar.Plug.Signals`, which already exports a function API.

    This module compiles only when the optional `:plug` dependency is
    present.
    """

    @behaviour Plug

    alias Datastar.Options

    @allowed_opts [:decoder, :max_length, :read_length]

    @doc """
    Validates the plug options, raising `ArgumentError` on an unknown key.

    Accepts `:decoder`, `:max_length` and `:read_length`; see
    `Datastar.Plug.Signals.read_signals/2`.
    """
    @impl true
    @spec init(keyword()) :: keyword()
    def init(opts), do: Options.validate!(opts, @allowed_opts)

    @doc """
    Reads the request's signals and assigns them as
    `conn.assigns.datastar_signals`.

    Raises `Datastar.Plug.Signals.Error` if the signals are malformed.
    """
    @impl true
    @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def call(conn, opts) do
      {signals, conn} = Datastar.Plug.Signals.read_signals!(conn, opts)

      Plug.Conn.assign(conn, :datastar_signals, signals)
    end
  end
end
