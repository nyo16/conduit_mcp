defmodule ConduitMcp.Client.OAuth.TokenStore.ETS do
  @moduledoc """
  The default `ConduitMcp.Client.OAuth.TokenStore`: an in-memory table,
  lost when the store stops.

  When a client's OAuth options name no `:store`, the client's supervisor
  starts one of these for that client. To share one store between clients
  (several servers behind the same authorization server, one user), start
  it yourself and name it in each client:

      children = [
        {ConduitMcp.Client.OAuth.TokenStore.ETS, name: :mcp_tokens},
        {ConduitMcp.Client, name: :docs, transport: {..., auth: {:oauth, store:
          {ConduitMcp.Client.OAuth.TokenStore.ETS, name: :mcp_tokens}, ...}}}
      ]

  `:name` may be any term; it is registered in `ConduitMcp.Client.Registry`.

  ## A protected table (OA-9)

  Unlike the library's other tables (see `ConduitMcp.EtsOwner`, which makes
  `:public` tables any process may write), this one is `:protected`: any
  process may read it, but only the store process writes it. Reads (every
  request's bearer lookup) go straight to ETS; writes (a new token, a
  rotated refresh token, a registered client) are a call to the store
  process. A bug or a compromised dependency elsewhere in the node can
  therefore read tokens it is handed the table for, but cannot plant or
  swap them.

  The store process implements `format_status/1`, so a crash report never
  shows a message carrying tokens.
  """

  use GenServer

  @behaviour ConduitMcp.Client.OAuth.TokenStore

  alias ConduitMcp.Client.OAuth.Tokens
  alias ConduitMcp.Client.Registry

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a store registered under `:name` (required)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: Registry.via({:token_store, name}))
  end

  @doc false
  # The store a client uses when its OAuth options name none.
  @spec default(term()) :: {module(), keyword()}
  def default(client), do: {__MODULE__, name: {:client, client}}

  # --- TokenStore ----------------------------------------------------------

  @impl ConduitMcp.Client.OAuth.TokenStore
  def fetch_tokens(key, opts), do: lookup(opts, {:tokens, key})

  @impl ConduitMcp.Client.OAuth.TokenStore
  def put_tokens(key, %Tokens{} = tokens, opts), do: write(opts, {:put, {:tokens, key}, tokens})

  @impl ConduitMcp.Client.OAuth.TokenStore
  def fetch_client(issuer, opts), do: lookup(opts, {:client, issuer})

  @impl ConduitMcp.Client.OAuth.TokenStore
  def put_client(issuer, client, opts) when is_map(client),
    do: write(opts, {:put, {:client, issuer}, client})

  @impl ConduitMcp.Client.OAuth.TokenStore
  def delete(key, what, opts) when what in [:tokens, :client] do
    _ = write(opts, {:delete, {what, key}})
    :ok
  end

  defp lookup(opts, row) do
    with {:ok, _pid, tid} <- Registry.lookup({:token_store, Keyword.fetch!(opts, :name)}),
         [{^row, value}] <- :ets.lookup(tid, row) do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    # The store stopped between the lookup and the read.
    ArgumentError -> :error
  end

  defp write(opts, message) do
    GenServer.call(Registry.via({:token_store, Keyword.fetch!(opts, :name)}), message)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  # --- GenServer -------------------------------------------------------------

  @impl GenServer
  def init(name) do
    tid = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    :ok = Registry.put_value({:token_store, name}, tid)
    {:ok, %{name: name, tid: tid}}
  end

  @impl GenServer
  def handle_call({:put, row, value}, _from, state) do
    true = :ets.insert(state.tid, {row, value})
    {:reply, :ok, state}
  end

  def handle_call({:delete, row}, _from, state) do
    true = :ets.delete(state.tid, row)
    {:reply, :ok, state}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end
end
