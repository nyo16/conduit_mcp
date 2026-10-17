defmodule ConduitMcp.Client.Registry do
  @moduledoc """
  The name of the passive, unique `Registry` that `ConduitMcp.Application`
  starts (partitioned by scheduler), and its key scheme.

  Every `ConduitMcp.Client` registers its processes here under tuple keys
  of its `:name`, so a name may be any term and no atom is ever created:

    * `{:supervisor, name}` - the `ConduitMcp.Client` supervisor.
    * `{:task_sup, name}` - the client's `Task.Supervisor`.
    * `{:client, name}` - the `ConduitMcp.Client.Connection`. Its value is
      `:starting` until the connection has initialised, then a map written
      once: the defaults callers need and the id of the client's
      `ConduitMcp.Client.Cache` table, where the connection keeps the state
      that changes (connection state, negotiated era and version, the
      server's capabilities, cached lists). `ConduitMcp.Client.status/1`
      and the request functions read both without messaging the
      connection.
    * `{:token_store, name}` - a `ConduitMcp.Client.OAuth.TokenStore.ETS`
      (`name` is `{:client, client_name}` for a client's default store).
      Its value is the id of its `:protected` table, read directly.

  A `ConduitMcp.Client.Hub` registers under its `:name` too:

    * `{:hub, name}` - the hub supervisor. Its value (`%{table: tid,
      config: %ConduitMcp.Client.Hub.Config{}}`) is written once in its
      `init/1`.
    * `{:hub_task_sup, name}`, `{:hub_servers, name}` (the
      `DynamicSupervisor` of server clients), `{:hub_manager, name}`.

  Each hub server is an ordinary client named `{:hub_server, hub, server_id}`,
  so its keys are `{:client, {:hub_server, hub, server_id}}` and so on.

  The registry holds no processes of its own. Nothing outside the client
  should write to it.
  """

  @registry __MODULE__

  @doc false
  @spec via(term()) :: {:via, Registry, {module(), term()}}
  def via(key), do: {:via, Registry, {@registry, key}}

  @doc false
  @spec via(term(), term()) :: {:via, Registry, {module(), term(), term()}}
  def via(key, value), do: {:via, Registry, {@registry, key, value}}

  @doc false
  # The pid and value registered under `key`, or `:error`.
  @spec lookup(term()) :: {:ok, pid(), term()} | :error
  def lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, value}] -> {:ok, pid, value}
      [] -> :error
    end
  end

  @doc false
  # Replaces the calling process's value under `key`; only the registered
  # process may call it.
  @spec put_value(term(), term()) :: :ok
  def put_value(key, value) do
    {_new, _old} = Registry.update_value(@registry, key, fn _ -> value end)
    :ok
  end
end
