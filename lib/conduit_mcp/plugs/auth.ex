defmodule ConduitMcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP servers.

  Provides flexible authentication strategies for protecting MCP endpoints.
  Supports bearer tokens, API keys, custom verification functions, and more.

  ## Options

  - `:enabled` - Enable/disable authentication (default: `true`)
  - `:strategy` - Authentication strategy: `:bearer_token`, `:api_key`, `:custom`, or `:function`
  - `:verify` - Verification function/MFA. Signature: `(credential :: String.t()) -> {:ok, user} | {:error, reason}`

    > #### The returned reason must not embed the credential {: .warning}
    >
    > A failure reason is written to the log (clamped and stripped of control
    > characters via `ConduitMcp.Reflect`). Telemetry deliberately reports the
    > coarse atom `:invalid_credential` instead, because metadata is shipped
    > verbatim to metrics backends. Return `{:error, :not_found}`, not
    > `{:error, "no user for token #{~s(abc123)}"}`.
  - `:token` - Static token for `:bearer_token` strategy (simple auth)
  - `:api_key` - Static API key for `:api_key` strategy
  - `:header` - Header name for `:api_key` strategy (default: `"x-api-key"`)
  - `:assign_as` - Key to assign authenticated user in conn.assigns (default: `:current_user`)
  - `:principal_id` - Explicit stable identity for the static `:bearer_token` /
    `:api_key` strategies. A shared static credential identifies exactly one
    principal; without this the id is a stable digest of the credential.
    See `ConduitMcp.Principal`.

  ## The authenticated principal

  On success this plug assigns:

    * `conn.assigns[:current_user]` (or `:assign_as`) — whatever your
      `:verify` function returned. Unchanged, and shaped however you like.
    * `conn.assigns[:mcp_principal]` — the canonical
      `ConduitMcp.Principal`, carrying a *stable scalar* `:id`. Task
      ownership and per-user rate limiting read this, never `:current_user`.

  Read it with `ConduitMcp.Principal.get/1` / `ConduitMcp.Principal.id/1`.

  ## Examples

  ### Disabled (Development)

      plug ConduitMcp.Plugs.Auth, enabled: false

  ### Static Bearer Token

      plug ConduitMcp.Plugs.Auth,
        strategy: :bearer_token,
        token: "my-secret-token"

  ### Static API Key

      plug ConduitMcp.Plugs.Auth,
        strategy: :api_key,
        api_key: "secret-key-123",
        header: "x-api-key"

  ### Custom Function (Anonymous)

      plug ConduitMcp.Plugs.Auth,
        strategy: :function,
        verify: fn token ->
          if MyApp.Auth.valid_token?(token) do
            {:ok, MyApp.Auth.get_user_by_token(token)}
          else
            {:error, "Invalid token"}
          end
        end

  ### Custom Function (MFA)

      plug ConduitMcp.Plugs.Auth,
        strategy: :function,
        verify: {MyApp.Auth, :verify_token, []}  # Will call MyApp.Auth.verify_token(token)

  ### Database Token Lookup

      plug ConduitMcp.Plugs.Auth,
        strategy: :function,
        verify: fn token ->
          case MyApp.Repo.get_by(ApiToken, token: token) do
            %ApiToken{user_id: user_id} ->
              user = MyApp.Repo.get!(User, user_id)
              {:ok, user}
            nil ->
              {:error, "Invalid token"}
          end
        end

  ### JWT Verification

      plug ConduitMcp.Plugs.Auth,
        strategy: :function,
        verify: fn token ->
          case MyApp.JWT.verify_and_validate(token) do
            {:ok, claims} ->
              user = MyApp.Accounts.get_user!(claims["sub"])
              {:ok, user}
            {:error, _reason} ->
              {:error, "Invalid JWT"}
          end
        end

  ### OAuth2 Integration

      plug ConduitMcp.Plugs.Auth,
        strategy: :function,
        verify: {MyApp.OAuth, :verify_token, []},
        assign_as: :oauth_user
  """

  import Plug.Conn
  require Logger

  alias ConduitMcp.Principal

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, true),
      strategy: Keyword.get(opts, :strategy, :bearer_token),
      verify: Keyword.get(opts, :verify),
      token: Keyword.get(opts, :token),
      api_key: Keyword.get(opts, :api_key),
      header: Keyword.get(opts, :header, "x-api-key"),
      assign_as: Keyword.get(opts, :assign_as, :current_user),
      principal_id: Keyword.get(opts, :principal_id)
    }
  end

  @impl true
  def call(conn, %{enabled: false} = _opts) do
    # Authentication disabled - pass through
    conn
  end

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    # Skip auth for CORS preflight requests
    conn
  end

  def call(conn, %{strategy: :bearer_token} = opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        verify_credential(conn, token, opts)

      ["bearer " <> token] ->
        verify_credential(conn, token, opts)

      _ ->
        unauthorized(conn, "Missing or invalid Authorization header")
    end
  end

  def call(conn, %{strategy: :api_key} = opts) do
    header_name = opts.header

    case get_req_header(conn, header_name) do
      [api_key] ->
        verify_credential(conn, api_key, opts)

      _ ->
        unauthorized(conn, "Missing #{header_name} header")
    end
  end

  def call(conn, %{strategy: :function} = opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        verify_credential(conn, token, opts)

      ["bearer " <> token] ->
        verify_credential(conn, token, opts)

      _ ->
        unauthorized(conn, "Missing or invalid Authorization header")
    end
  end

  def call(conn, %{strategy: :custom} = opts) do
    # Deprecated: use :function instead
    Logger.warning("Auth strategy :custom is deprecated, use :function instead")
    call(conn, Map.put(opts, :strategy, :function))
  end

  def call(conn, opts) do
    Logger.error("Invalid auth strategy: #{inspect(opts.strategy)}")
    unauthorized(conn, "Server configuration error")
  end

  defp verify_credential(conn, credential, opts) do
    start_time = System.monotonic_time()

    result =
      case do_verify(credential, opts) do
        {:ok, user} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:conduit_mcp, :auth, :verify],
            %{duration: duration},
            %{strategy: opts.strategy, status: :ok}
          )

          conn
          |> assign_user(user, opts.assign_as)
          |> Principal.put(build_principal(user, credential, opts))

        {:error, reason} ->
          duration = System.monotonic_time() - start_time

          # A coarse atom, not the verifier's reason. A `:verify` function is
          # free to return the credential (or something derived from it) as
          # its reason, and telemetry metadata is shipped to metrics backends
          # and logs — see the `:verify` contract note in the moduledoc.
          :telemetry.execute(
            [:conduit_mcp, :auth, :verify],
            %{duration: duration},
            %{strategy: opts.strategy, status: :error, reason: :invalid_credential}
          )

          Logger.warning("Authentication failed: #{ConduitMcp.Reflect.text(reason)}")
          unauthorized(conn, "Authentication failed")

        other ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:conduit_mcp, :auth, :verify],
            %{duration: duration},
            %{strategy: opts.strategy, status: :error, reason: :invalid_return}
          )

          Logger.error("Invalid verify function return: #{inspect(other)}")
          unauthorized(conn, "Server configuration error")
      end

    result
  end

  # The static strategies previously assigned the constant
  # `%{authenticated: true}`, which carries no identity at all. Everything
  # downstream that needs to tell two callers apart reads
  # `ConduitMcp.Principal` instead.
  defp build_principal(user, credential, opts) do
    %{
      id: opts.principal_id || Principal.derive_id(user) || credential_id(credential),
      scopes: user_scopes(user),
      strategy: opts.strategy,
      user: user
    }
  end

  # A shared static secret identifies exactly one principal. Digest it so the
  # id is stable across requests and restarts without echoing the credential.
  # The credential always comes from a request header, so it is always a
  # binary; dialyzer proves a non-binary clause here is unreachable.
  defp credential_id(credential) when is_binary(credential) do
    digest = :crypto.hash(:sha256, credential) |> binary_part(0, 12)
    "static:" <> Base.url_encode64(digest, padding: false)
  end

  defp user_scopes(%{scopes: scopes}) when is_list(scopes), do: scopes
  defp user_scopes(%{"scopes" => scopes}) when is_list(scopes), do: scopes
  defp user_scopes(_user), do: []

  defp do_verify(credential, %{strategy: :bearer_token, token: expected_token})
       when not is_nil(expected_token) do
    if Plug.Crypto.secure_compare(credential, expected_token) do
      {:ok, %{authenticated: true}}
    else
      {:error, "Invalid token"}
    end
  end

  defp do_verify(credential, %{strategy: :api_key, api_key: expected_key})
       when not is_nil(expected_key) do
    if Plug.Crypto.secure_compare(credential, expected_key) do
      {:ok, %{authenticated: true}}
    else
      {:error, "Invalid API key"}
    end
  end

  defp do_verify(credential, %{verify: verify_fn}) when is_function(verify_fn, 1) do
    verify_fn.(credential)
  end

  defp do_verify(credential, %{verify: {module, function, args}}) do
    apply(module, function, [credential | args])
  end

  defp do_verify(_credential, opts) do
    Logger.error("No verification method configured for strategy: #{opts.strategy}")
    {:error, "Configuration error"}
  end

  defp assign_user(conn, user, assign_key) do
    assign(conn, assign_key, user)
  end

  defp unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, JSON.encode!(%{"error" => "Unauthorized", "message" => message}))
    |> halt()
  end
end
