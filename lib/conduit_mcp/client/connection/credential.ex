defmodule ConduitMcp.Client.Connection.Credential do
  @moduledoc false

  # The identity of the credentials the connection sends, which keys its
  # private cached results (HT-11, `ConduitMcp.Client.Cache`), and
  # `ConduitMcp.Client.set_auth/3`, which replaces them.
  #
  # The identity is a digest, never a token: the cache table is readable by
  # any process.
  #
  #   * no `:auth` - `nil`;
  #   * `{:bearer, token}` - `{:bearer, sha256(token)}`;
  #   * OAuth - `{:oauth, sha256({principal, issuer, resource})}`, the key
  #     the tokens are stored under (issuer and resource `nil` until
  #     discovery), so a refresh for the same principal keeps it;
  #   * an `:auth` function - `{:declared, sha256(credential_id)}` when the
  #     transport's `:credential_id` says whose tokens it returns, else
  #     `:unshared`: it runs before every request and may return anyone's,
  #     so nothing private fetched with it is served again.

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.OAuth.Config, as: OAuthConfig
  alias ConduitMcp.Client.OAuth.TokenStore
  alias ConduitMcp.Client.Secret

  @doc "The identity of the credentials `data`'s configuration sends now."
  @spec identity(Data.t()) :: Cache.credential()
  def identity(%Data{config: %{transport: {_transport, opts}}, auth: auth}) do
    case Keyword.get(opts, :auth) do
      nil ->
        nil

      {:bearer, token} ->
        {:bearer, digest(text(token))}

      fun when is_function(fun, 1) ->
        case Keyword.get(opts, :credential_id) do
          nil -> :unshared
          id -> {:declared, digest(:erlang.term_to_binary(id, [:deterministic]))}
        end

      {:oauth, %OAuthConfig{} = config} ->
        {:oauth, digest(:erlang.term_to_binary(oauth_key(config, auth), [:deterministic]))}

      _unknown ->
        :unshared
    end
  end

  # The session's key once discovery ran; the configured principal before.
  defp oauth_key(_config, %{session: %{config: config, context: %{} = context}}),
    do: {config.principal, context.issuer, context.resource}

  defp oauth_key(config, _not_discovered), do: {config.principal, nil, nil}

  @doc """
  Records the identity in the cache (deleting private lists when it
  changed). Runs whenever the credentials may have changed: after the OAuth
  session reaches the transport, and after `set_auth`.
  """
  @spec sync(Data.t()) :: Data.t()
  def sync(%Data{} = data) do
    _changed? = Cache.put_credential(data.cache, identity(data))
    data
  end

  @doc """
  The transport options with `auth` (and `credential_id`) in place of the
  current ones, validated by the transport. OAuth options naming no
  `:store` keep the store the client uses now; a client that started
  without OAuth has none, so they must name one.
  """
  @spec replace(Data.t(), term(), term()) :: {:ok, keyword()} | {:error, String.t()}
  def replace(%Data{config: %{transport: {transport, opts}} = config}, auth, credential_id) do
    current = Keyword.get(opts, :auth)

    with {:ok, auth} <- inherit_store(auth, current, config.name),
         do: validate(transport, put_auth(opts, auth, credential_id))
  end

  defp put_auth(opts, auth, credential_id) do
    opts = Keyword.put(opts, :auth, auth)

    if credential_id != nil or Keyword.has_key?(opts, :credential_id),
      do: Keyword.put(opts, :credential_id, credential_id),
      else: opts
  end

  defp validate(transport, opts) do
    if function_exported?(transport, :validate_options, 1),
      do: transport.validate_options(opts),
      else: {:error, "#{inspect(transport)} takes no :auth option"}
  end

  defp inherit_store({grant, oauth_opts} = auth, current, name)
       when grant in [:oauth, :client_credentials] and is_list(oauth_opts) do
    cond do
      Keyword.has_key?(oauth_opts, :store) ->
        {:ok, auth}

      match?({:oauth, %OAuthConfig{}}, current) ->
        {:oauth, %OAuthConfig{store: store}} = current
        {:ok, {grant, Keyword.put(oauth_opts, :store, store || TokenStore.ETS.default(name))}}

      true ->
        {:error,
         "invalid value for :auth option: the client started without OAuth, so it has " <>
           "no token store; name a :store"}
    end
  end

  defp inherit_store(auth, _current, _name), do: {:ok, auth}

  defp text(token), do: if(Secret.secret?(token), do: Secret.expose(token), else: token)

  defp digest(binary), do: :crypto.hash(:sha256, binary)
end
