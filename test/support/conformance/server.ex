defmodule Datastar.Conformance.Server do
  @moduledoc """
  Boots `Datastar.Conformance.Router` on Bandit for the official runner
  (default port 7331, spec §11.1). `run/1` blocks, for
  `MIX_ENV=test mix run --no-halt`.
  """

  @default_port 7331

  @doc "Starts `Datastar.Conformance.Router` on Bandit, listening on `port`."
  @spec start(:inet.port_number()) :: {:ok, pid()} | {:error, term()}
  def start(port \\ @default_port) do
    Bandit.start_link(plug: Datastar.Conformance.Router, port: port)
  end

  @doc "Starts the server and blocks forever, for `mix run --no-halt`."
  @spec run(:inet.port_number()) :: no_return()
  def run(port \\ @default_port) do
    case start(port) do
      {:ok, _pid} ->
        IO.puts("datastar conformance server listening on port #{port}")
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "conformance server failed to start: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
