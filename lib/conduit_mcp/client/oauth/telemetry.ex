defmodule ConduitMcp.Client.OAuth.Telemetry do
  @moduledoc false

  # The `[:conduit_mcp, :client, :oauth, ...]` events (documented in
  # `ConduitMcp.Telemetry`), emitted with literal event names. Metadata is
  # an allowlist (TL-1): the client's name and server id (`nil` for a
  # standalone configuration), the host-supplied principal, and closed-set
  # atoms. Never a token, code, state, verifier, secret, URL or issuer.

  alias ConduitMcp.Client.OAuth.{Config, Error}

  @type op :: :discovery | :registration | :token_exchange | :refresh | :step_up

  @doc "The allowlisted base metadata of `config`."
  @spec base(Config.t()) :: map()
  def base(%Config{} = config),
    do: %{client: config.client, server_id: config.server_id, principal: config.principal}

  @doc """
  Runs `fun` inside the `op` span. `fun` returns `{result, extra}`, where
  `extra` is merged into the `:stop` metadata; `:status` and `:reason` are
  derived from `result` (`{:ok, _}` / `:ok` or `{:error, %OAuth.Error{}}`).
  """
  @spec span(op(), map(), (-> {result, map()})) :: result when result: term()
  def span(op, meta, fun) do
    start = System.monotonic_time()
    emit(op, :start, %{monotonic_time: start, system_time: System.system_time()}, meta)

    try do
      {result, extra} = fun.()
      stop = %{duration: System.monotonic_time() - start, monotonic_time: System.monotonic_time()}
      emit(op, :stop, stop, meta |> Map.merge(outcome(result)) |> Map.merge(extra))
      result
    catch
      kind, reason ->
        stop = %{
          duration: System.monotonic_time() - start,
          monotonic_time: System.monotonic_time()
        }

        emit(op, :exception, stop, Map.put(meta, :kind, kind))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "The host was told that the user must authorize."
  @spec authorization_required(map(), :unauthorized | :step_up) :: :ok
  def authorization_required(meta, reason) do
    :telemetry.execute(
      [:conduit_mcp, :client, :oauth, :authorization_required],
      %{count: 1},
      Map.put(meta, :reason, reason)
    )
  end

  defp outcome({:error, %Error{reason: reason}}), do: %{status: :error, reason: reason}
  defp outcome({:error, _other}), do: %{status: :error, reason: nil}
  defp outcome(_ok), do: %{status: :ok, reason: nil}

  defp emit(:discovery, :start, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :discovery, :start], m, md)

  defp emit(:discovery, :stop, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :discovery, :stop], m, md)

  defp emit(:discovery, :exception, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :discovery, :exception], m, md)

  defp emit(:registration, :start, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :registration, :start], m, md)

  defp emit(:registration, :stop, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :registration, :stop], m, md)

  defp emit(:registration, :exception, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :registration, :exception], m, md)

  defp emit(:token_exchange, :start, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :token_exchange, :start], m, md)

  defp emit(:token_exchange, :stop, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :token_exchange, :stop], m, md)

  defp emit(:token_exchange, :exception, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :token_exchange, :exception], m, md)

  defp emit(:refresh, :start, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :refresh, :start], m, md)

  defp emit(:refresh, :stop, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :refresh, :stop], m, md)

  defp emit(:refresh, :exception, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :refresh, :exception], m, md)

  defp emit(:step_up, :start, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :step_up, :start], m, md)

  defp emit(:step_up, :stop, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :step_up, :stop], m, md)

  defp emit(:step_up, :exception, m, md),
    do: :telemetry.execute([:conduit_mcp, :client, :oauth, :step_up, :exception], m, md)
end
