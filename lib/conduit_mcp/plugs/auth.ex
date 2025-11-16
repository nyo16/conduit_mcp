defmodule ConduitMcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP servers.

  Provides flexible authentication strategies for protecting MCP endpoints.
  Supports bearer tokens, API keys, custom verification functions, and more.

  ## Options

  - `:enabled` - Enable/disable authentication (default: `true`)
  - `:strategy` - Authentication strategy: `:bearer_token`, `:api_key`, `:custom`, or `:function`
  - `:verify` - Verification function/MFA. Signature: `(credential :: String.t()) -> {:ok, user} | {:error, reason}`
  - `:token` - Static token for `:bearer_token` strategy (simple auth)
  - `:api_key` - Static API key for `:api_key` strategy
  - `:header` - Header name for `:api_key` strategy (default: `"x-api-key"`)
  - `:assign_as` - Key to assign authenticated user in conn.assigns (default: `:current_user`)

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
      assign_as: Keyword.get(opts, :assign_as, :current_user)
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

          assign_user(conn, user, opts.assign_as)

        {:error, reason} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:conduit_mcp, :auth, :verify],
            %{duration: duration},
            %{strategy: opts.strategy, status: :error, reason: reason}
          )

          Logger.warning("Authentication failed: #{inspect(reason)}")
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

  defp do_verify(credential, %{strategy: :bearer_token, token: expected_token}) when not is_nil(expected_token) do
    if credential == expected_token do
      {:ok, %{authenticated: true}}
    else
      {:error, "Invalid token"}
    end
  end

  defp do_verify(credential, %{strategy: :api_key, api_key: expected_key}) when not is_nil(expected_key) do
    if credential == expected_key do
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
    |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized", "message" => message}))
    |> halt()
  end
end
