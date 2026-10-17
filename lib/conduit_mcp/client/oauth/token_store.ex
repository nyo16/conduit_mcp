defmodule ConduitMcp.Client.OAuth.TokenStore do
  @moduledoc """
  Where the OAuth client keeps tokens and registered clients.

  Configure one as `store: {module, opts}` in the client's OAuth options;
  `opts` is passed as the last argument of every callback. The default is
  `ConduitMcp.Client.OAuth.TokenStore.ETS`: in memory, lost when the client
  stops. Implement this behaviour to persist tokens (a database, the OS
  keychain, an encrypted file).

  ## Keys

    * Tokens are stored under `{principal, issuer, resource}`: the host's
      identity for the user (`:principal`, `nil` when unused), the
      authorization server's `issuer`, and the MCP server's canonical
      resource URI. A token is therefore never used for another server,
      another authorization server, or another user - even when two
      servers trust the same authorization server (OA-5).
    * Registered clients (dynamic client registration) are stored under the
      issuer alone: credentials issued by one authorization server are
      never presented to another (OA-6).

  ## Values

  Tokens are `ConduitMcp.Client.OAuth.Tokens` structs; the access and
  refresh tokens inside are `ConduitMcp.Client.Secret`s. A client is a
  string-keyed map: `"client_id"`, `"client_secret"` (a `Secret` or `nil`),
  `"token_endpoint_auth_method"` and `"redirect_uris"`. A store that
  serializes values must call `ConduitMcp.Client.Secret.expose/1` and wrap
  again on the way back, and should encrypt them at rest.

  ## Single-flight refresh

  `transaction/3` runs `fun` while holding a lock on `key`, so that of many
  processes finding the same expired token only one refreshes it and the
  others re-read the store inside the lock and find the new token. It is
  optional: the default (`transaction/4` here) is a node-local
  `:global.trans/4` on `{#{inspect(__MODULE__)}, key}`. A store shared
  across nodes (a database) should implement it with its own lock, for
  example `SELECT ... FOR UPDATE`.
  """

  alias ConduitMcp.Client.OAuth.Tokens

  @type key :: {principal :: term(), issuer :: String.t(), resource :: String.t()}
  @type issuer :: String.t()
  @type client :: %{optional(String.t()) => term()}

  @callback fetch_tokens(key(), opts :: keyword()) :: {:ok, Tokens.t()} | :error
  @callback put_tokens(key(), Tokens.t(), opts :: keyword()) :: :ok | {:error, term()}
  @callback fetch_client(issuer(), opts :: keyword()) :: {:ok, client()} | :error
  @callback put_client(issuer(), client(), opts :: keyword()) :: :ok | {:error, term()}
  @callback delete(key() | issuer(), :tokens | :client, opts :: keyword()) :: :ok
  @callback transaction(key(), (-> result), opts :: keyword()) :: result when result: var

  @optional_callbacks transaction: 3

  @type store :: {module(), keyword()}

  @doc false
  @spec fetch_tokens(store(), key()) :: {:ok, Tokens.t()} | :error
  def fetch_tokens({module, opts}, key) do
    case module.fetch_tokens(key, opts) do
      {:ok, %Tokens{} = tokens} -> {:ok, tokens}
      _other -> :error
    end
  end

  @doc false
  @spec put_tokens(store(), key(), Tokens.t()) :: :ok | {:error, term()}
  def put_tokens({module, opts}, key, %Tokens{} = tokens),
    do: module.put_tokens(key, tokens, opts)

  @doc false
  @spec fetch_client(store(), issuer()) :: {:ok, client()} | :error
  def fetch_client({module, opts}, issuer) do
    case module.fetch_client(issuer, opts) do
      {:ok, %{} = client} -> {:ok, client}
      _other -> :error
    end
  end

  @doc false
  @spec put_client(store(), issuer(), client()) :: :ok | {:error, term()}
  def put_client({module, opts}, issuer, client), do: module.put_client(issuer, client, opts)

  @doc false
  @spec delete(store(), key() | issuer(), :tokens | :client) :: :ok
  def delete({module, opts}, key, what), do: module.delete(key, what, opts)

  @doc """
  Runs `fun` under the store's lock for `key`: the store's own
  `c:transaction/3` when it has one, else a node-local
  `:global.trans/4`.
  """
  @spec transaction(store(), key(), (-> result)) :: result when result: var
  def transaction({module, opts}, key, fun) do
    if function_exported?(module, :transaction, 3) do
      module.transaction(key, fun, opts)
    else
      :global.trans({{__MODULE__, key}, self()}, fun, [node()], :infinity)
    end
  end
end
