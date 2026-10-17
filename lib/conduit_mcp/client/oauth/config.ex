defmodule ConduitMcp.Client.OAuth.Config do
  @client_schema [
    client_id: [type: :string, required: true, doc: "The client id."],
    client_secret: [
      type: {:custom, __MODULE__, :validate_secret, []},
      doc: """
      The client secret: a string, a `ConduitMcp.Client.Secret`, or
      `{:system, "VAR"}` (read from the environment when a token is
      requested, never stored).
      """
    ],
    private_key: [
      type: {:custom, __MODULE__, :validate_private_key, []},
      doc: """
      A private JWK (a map, or a PEM string) for `private_key_jwt` client
      authentication (RFC 7523). Needs the optional `:jose` dependency.
      """
    ],
    private_key_alg: [
      type: :string,
      default: "RS256",
      doc: "The JWS algorithm of the client assertion."
    ],
    private_key_kid: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "The `kid` header of the client assertion."
    ],
    token_endpoint_auth_method: [
      type: {:in, [:none, :client_secret_basic, :client_secret_post, :private_key_jwt]},
      doc: """
      How the client authenticates at the token endpoint. Default:
      `:private_key_jwt` with a `:private_key`, `:client_secret_basic` with a
      `:client_secret`, else `:none` (a public client).
      """
    ]
  ]

  @schema NimbleOptions.new!(
            server_url: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The MCP server's URL. Filled in by the transport; required for a
              standalone configuration passed to `ConduitMcp.Client.OAuth`.
              """
            ],
            grant: [
              type: {:in, [:authorization_code, :client_credentials]},
              default: :authorization_code,
              doc: """
              `:authorization_code` (a user authorizes in a browser) or
              `:client_credentials` (machine to machine; set by
              `auth: {:client_credentials, opts}`).
              """
            ],
            redirect_uri: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The redirect URI registered for the client: `https`, or `http` on
              a loopback host (RFC 8252). `ConduitMcp.Client.OAuth.authorize_url/2`
              may override it (as `ConduitMcp.Client.OAuth.Loopback` does).
              """
            ],
            client_metadata_url: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The `https` URL (with a path) of the client's Client ID Metadata
              Document. When the authorization server advertises
              `client_id_metadata_document_supported`, this URL **is** the
              client id. Host the document (`ConduitMcp.Client.OAuth.CIMD.document/1`)
              at that URL.
              """
            ],
            client_metadata: [
              type: :keyword_list,
              default: [],
              keys: [
                client_name: [
                  type: :string,
                  doc: "Shown to the user by the authorization server."
                ],
                application_type: [
                  type: {:in, [:native, :web]},
                  doc: """
                  The dynamic-registration `application_type`. Default:
                  `:native` for a loopback or custom-scheme redirect URI, else `:web`.
                  """
                ],
                client_uri: [type: :string, doc: "The client's home page."],
                logo_uri: [type: :string, doc: "The client's logo."]
              ],
              doc: "Metadata sent in a dynamic client registration request."
            ],
            pre_registered: [
              type: {:custom, __MODULE__, :validate_pre_registered, []},
              default: %{},
              doc: """
              Clients registered out of band, as a map from the authorization
              server's issuer (exact string) to client options:

              #{NimbleOptions.docs(NimbleOptions.new!(@client_schema), nest_level: 1)}
              """
            ],
            store: [
              type: {:custom, __MODULE__, :validate_store, []},
              default: nil,
              doc: """
              The `ConduitMcp.Client.OAuth.TokenStore` as `{module, opts}`.
              Default: an in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS`
              started under the client's supervisor, or, for a
              `ConduitMcp.Client.Hub` server, the hub's, shared by its servers.
              """
            ],
            on_authorization_required: [
              type: {:or, [{:fun, 1}, nil]},
              default: nil,
              doc: """
              Called with a `ConduitMcp.Client.OAuth.Challenge` when the user
              must authorize (in a task, never in the connection). Start the
              flow with `ConduitMcp.Client.OAuth.authorize_url/2`.
              """
            ],
            max_step_up_attempts: [
              type: :non_neg_integer,
              default: 2,
              doc: "Step-up authorizations allowed per resource and scope set."
            ],
            refresh_skew: [
              type: :non_neg_integer,
              default: 30,
              doc: "Seconds before expiry at which an access token is refreshed."
            ],
            expected_issuers: [
              type: {:or, [{:list, :string}, nil]},
              default: nil,
              doc: """
              When a list, the authorization server the server names must be
              one of these issuers (exact match). `nil` accepts any.
              """
            ],
            principal: [
              type: :any,
              default: nil,
              doc: """
              The identity tokens are stored under, part of every token-store
              key: the end user or tenant this client acts for.
              """
            ],
            scopes: [
              type: {:list, :string},
              default: [],
              doc: """
              Scopes to request when neither the server's challenge nor its
              metadata names any (always requested by `:client_credentials`).
              """
            ],
            client_id: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: "`:client_credentials` only."
            ],
            client_secret: [
              type: {:custom, __MODULE__, :validate_secret, []},
              doc: "`:client_credentials` only; see `:pre_registered`."
            ],
            private_key: [
              type: {:custom, __MODULE__, :validate_private_key, []},
              doc: "`:client_credentials` only; see `:pre_registered`."
            ],
            private_key_alg: [type: :string, default: "RS256", doc: "See `:pre_registered`."],
            private_key_kid: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: "See `:pre_registered`."
            ],
            token_endpoint_auth_method: [
              type: {:in, [:none, :client_secret_basic, :client_secret_post, :private_key_jwt]},
              doc: "`:client_credentials` only; see `:pre_registered`."
            ],
            allow_insecure_oauth: [
              type: :boolean,
              default: false,
              doc: """
              Development and tests only: admit plain `http` metadata and
              authorization-server URLs on loopback hosts.
              """
            ],
            allow_private: [
              type: {:list, :any},
              default: [],
              doc: """
              CIDRs the URL policy admits for OAuth requests although they are
              private (see `ConduitMcp.Client.URLPolicy`).
              """
            ],
            resolver: [
              type: {:or, [{:fun, 1}, nil]},
              default: nil,
              doc: "The DNS resolver for the URL policy (see `ConduitMcp.Client.URLPolicy`)."
            ],
            transport_opts: [
              type: :keyword_list,
              default: [],
              doc:
                "TLS options for OAuth requests (Mint `:transport_opts`, for example `cacerts:`)."
            ],
            request_timeout: [
              type: :pos_integer,
              default: 10_000,
              doc: "Milliseconds for each OAuth HTTP request."
            ],
            clock: [
              type: {:or, [{:fun, 0}, nil]},
              default: nil,
              doc: "Returns the current Unix time in seconds (tests). Default: the system clock."
            ],
            client: [type: :any, default: nil, doc: false],
            server_id: [type: :any, default: nil, doc: false]
          )

  @moduledoc """
  The options of the client's OAuth 2.1 support, validated into a struct.

  Given to the Streamable HTTP transport as `auth: {:oauth, opts}` (or
  `auth: {:client_credentials, opts}`), or built with `new!/1` for a
  standalone flow with `ConduitMcp.Client.OAuth`.

      auth: {:oauth,
        redirect_uri: "http://127.0.0.1:33418/callback",
        client_metadata_url: "https://app.example.com/oauth/client.json",
        client_metadata: [client_name: "My Agent", application_type: :native],
        pre_registered: %{"https://auth.example.com" => [client_id: "abc"]},
        on_authorization_required: &MyApp.Auth.prompt/1,
        expected_issuers: ["https://auth.example.com"]}

  Secrets (client secrets, private keys) are held as
  `ConduitMcp.Client.Secret`s.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias ConduitMcp.Client.OAuth.{CIMD, Error, Pending, TokenStore}
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.URLPolicy

  @typedoc """
  A client identity: the id, how it authenticates at the token endpoint,
  and its credentials.
  """
  @type client_credentials :: %{
          client_id: String.t(),
          auth_method: :none | :client_secret_basic | :client_secret_post | :private_key_jwt,
          secret: Secret.t() | {:system, String.t()} | nil,
          private_key: Secret.t() | nil,
          alg: String.t(),
          kid: String.t() | nil
        }

  defstruct server_url: nil,
            grant: :authorization_code,
            redirect_uri: nil,
            client_metadata_url: nil,
            client_metadata: [],
            pre_registered: %{},
            store: nil,
            on_authorization_required: nil,
            max_step_up_attempts: 2,
            refresh_skew: 30,
            expected_issuers: nil,
            principal: nil,
            scopes: [],
            credentials: nil,
            allow_insecure_oauth: false,
            allow_private: [],
            resolver: nil,
            transport_opts: [],
            request_timeout: 10_000,
            clock: nil,
            client: nil,
            server_id: nil

  @type t :: %__MODULE__{
          server_url: String.t() | nil,
          grant: :authorization_code | :client_credentials,
          redirect_uri: String.t() | nil,
          client_metadata_url: String.t() | nil,
          client_metadata: keyword(),
          pre_registered: %{optional(String.t()) => client_credentials()},
          store: {module(), keyword()} | nil,
          on_authorization_required: (term() -> term()) | nil,
          max_step_up_attempts: non_neg_integer(),
          refresh_skew: non_neg_integer(),
          expected_issuers: [String.t()] | nil,
          principal: term(),
          scopes: [String.t()],
          credentials: client_credentials() | nil,
          allow_insecure_oauth: boolean(),
          allow_private: [term()],
          resolver: URLPolicy.resolver() | nil,
          transport_opts: keyword(),
          request_timeout: pos_integer(),
          clock: (-> integer()) | nil,
          client: term(),
          server_id: term()
        }

  @credential_keys [
    :client_id,
    :client_secret,
    :private_key,
    :private_key_alg,
    :private_key_kid,
    :token_endpoint_auth_method
  ]

  @doc """
  Validates `opts` into a config. Returns `{:error, message}` on an
  invalid option.
  """
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = config), do: {:ok, config}

  def new(opts) when is_list(opts) do
    with {:ok, valid} <- schema_validate(opts),
         {:ok, valid} <- check_urls(valid),
         {:ok, credentials} <- credentials(valid) do
      fields = valid |> Keyword.drop(@credential_keys) |> Keyword.put(:credentials, credentials)
      {:ok, struct!(__MODULE__, fields)}
    end
  end

  def new(other), do: {:error, "expected OAuth options as a keyword list, got: #{inspect(other)}"}

  @doc "Like `new/1`, raising `ArgumentError`."
  @spec new!(keyword() | t()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp schema_validate(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, valid} -> {:ok, valid}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp check_urls(valid) do
    cond do
      valid[:redirect_uri] &&
          match?({:error, _}, Pending.validate_redirect_uri(valid[:redirect_uri])) ->
        {:error,
         "invalid value for :redirect_uri option: expected an https URL, or http on a " <>
           "loopback host, without a fragment"}

      valid[:client_metadata_url] && not CIMD.valid_url?(valid[:client_metadata_url]) ->
        {:error,
         "invalid value for :client_metadata_url option: expected an https URL with a path"}

      Enum.any?(valid[:allow_private], &(URLPolicy.parse_cidr(&1) == :error)) ->
        {:error, "invalid value for :allow_private option: expected CIDRs"}

      true ->
        {:ok, valid}
    end
  end

  defp credentials(valid) do
    case {valid[:grant], valid[:client_id]} do
      {:client_credentials, nil} ->
        {:error, "required :client_id option not found (auth: {:client_credentials, ...})"}

      {:client_credentials, _id} ->
        client = client(Keyword.take(valid, @credential_keys))

        if client.auth_method == :none,
          do:
            {:error, "auth: {:client_credentials, ...} needs a :client_secret or a :private_key"},
          else: {:ok, client}

      {_grant, _id} ->
        {:ok, nil}
    end
  end

  # An internal client identity from validated client options.
  defp client(opts) do
    secret = opts[:client_secret]
    key = opts[:private_key]

    method =
      opts[:token_endpoint_auth_method] ||
        cond do
          key != nil -> :private_key_jwt
          secret != nil -> :client_secret_basic
          true -> :none
        end

    %{
      client_id: opts[:client_id],
      auth_method: method,
      secret: secret,
      private_key: key,
      alg: opts[:private_key_alg] || "RS256",
      kid: opts[:private_key_kid]
    }
  end

  # --- accessors ---------------------------------------------------------

  @doc false
  # The context of `ConduitMcp.Client.OAuth.HTTP` requests.
  @spec http(t()) :: map()
  def http(%__MODULE__{} = config) do
    %{
      allow_insecure: config.allow_insecure_oauth,
      allow_private: config.allow_private,
      resolver: config.resolver,
      transport_opts: config.transport_opts,
      timeout: config.request_timeout
    }
  end

  @doc false
  # Options for the pure URL helpers (`Resource`, `Discovery`).
  @spec url_opts(t()) :: keyword()
  def url_opts(%__MODULE__{} = config), do: [allow_insecure: config.allow_insecure_oauth]

  @doc false
  @spec now(t()) :: integer()
  def now(%__MODULE__{clock: nil}), do: System.os_time(:second)
  def now(%__MODULE__{clock: clock}), do: clock.()

  @doc false
  # The store, or the default one of `client` (a client's name).
  @spec store(t()) :: {module(), keyword()}
  def store(%__MODULE__{store: {_module, _opts} = store}), do: store
  def store(%__MODULE__{client: client}), do: TokenStore.ETS.default(client)

  @doc false
  # The plain client secret, read now (`{:system, var}` from the environment).
  @spec secret(client_credentials()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def secret(%{secret: nil}), do: {:ok, nil}

  def secret(%{secret: {:system, var}}) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _unset -> Error.error(:client_secret_unavailable, var)
    end
  end

  def secret(%{secret: secret}), do: {:ok, Secret.expose(secret)}

  # --- validators ----------------------------------------------------------

  @doc false
  @spec validate_secret(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_secret({:system, var}) when is_binary(var) and var != "", do: {:ok, {:system, var}}

  def validate_secret(value) do
    plain = if Secret.secret?(value), do: Secret.expose(value), else: value

    if is_binary(plain) and plain != "",
      do: {:ok, Secret.new(plain)},
      else:
        {:error, "expected a non-empty string, a ConduitMcp.Client.Secret or {:system, \"VAR\"}"}
  end

  @doc false
  @spec validate_private_key(term()) :: {:ok, Secret.t()} | {:error, String.t()}
  def validate_private_key(value) do
    plain = if Secret.secret?(value), do: Secret.expose(value), else: value

    if is_map(plain) or (is_binary(plain) and plain != "") do
      _module = ConduitMcp.OptionalDeps.client_assertion!()
      {:ok, Secret.new(plain)}
    else
      {:error, "expected a private JWK map or a PEM string"}
    end
  end

  @doc false
  @spec validate_pre_registered(term()) :: {:ok, map()} | {:error, String.t()}
  def validate_pre_registered(map) when is_map(map) do
    schema = NimbleOptions.new!(@client_schema)

    Enum.reduce_while(map, {:ok, %{}}, fn
      {issuer, opts}, {:ok, acc} when is_binary(issuer) and is_list(opts) ->
        case NimbleOptions.validate(opts, schema) do
          {:ok, valid} ->
            {:cont, {:ok, Map.put(acc, issuer, client(valid))}}

          {:error, error} ->
            {:halt, {:error, "for issuer #{inspect(issuer)}: " <> Exception.message(error)}}
        end

      {issuer, %{client_id: _} = client}, {:ok, acc} when is_binary(issuer) ->
        # Already validated (a config passed through validation twice).
        {:cont, {:ok, Map.put(acc, issuer, client)}}

      _entry, _acc ->
        {:halt, {:error, "expected a map of issuer => client options"}}
    end)
  end

  def validate_pre_registered(_other), do: {:error, "expected a map of issuer => client options"}

  @doc false
  @spec validate_store(term()) :: {:ok, {module(), keyword()} | nil} | {:error, String.t()}
  def validate_store(nil), do: {:ok, nil}

  def validate_store({module, opts} = store) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :fetch_tokens, 2),
      do: {:ok, store},
      else: {:error, "#{inspect(module)} does not implement ConduitMcp.Client.OAuth.TokenStore"}
  end

  def validate_store(_other), do: {:error, "expected {module, opts} or nil"}

  defimpl Inspect do
    # The fields hold Secrets (inspect-safe) and functions; keep the shape
    # short and never show the client map's secret fields.
    def inspect(config, _opts) do
      "#ConduitMcp.Client.OAuth.Config<grant: #{config.grant}, server_url: " <>
        "#{Kernel.inspect(config.server_url)}>"
    end
  end
end
