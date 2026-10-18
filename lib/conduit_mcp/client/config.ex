defmodule ConduitMcp.Client.Config do
  alias ConduitMcp.Client.Backoff
  alias ConduitMcp.Client.Negotiation

  @protocols [:auto, :modern, :legacy]

  @telemetry_keys [
    capture_payloads: [
      type: {:custom, __MODULE__, :validate_capture_payloads, []},
      default: false,
      doc: """
      Opt-in capture of tool-call payloads in the
      `[:conduit_mcp, :client, :tool_call, ...]` span (TL-2). `false`
      (the default): the span's metadata has no `:arguments` or
      `:result` key at all. To enable it, pass `[redact: fun, max_bytes:
      n]`: `:redact` (**required**; `true` alone is rejected) is a
      one-arity function run in the calling process on the arguments
      and on the result before they reach any handler, and `:max_bytes`
      (default 4 096) caps the JSON size of what it returns. See
      "Payload capture" in `ConduitMcp.Telemetry`.
      """
    ]
  ]

  @telemetry_schema NimbleOptions.new!(@telemetry_keys)

  @capture_schema NimbleOptions.new!(
                    redact: [type: {:fun, 1}, required: true],
                    max_bytes: [type: :pos_integer, default: 4_096]
                  )

  @schema NimbleOptions.new!(
            name: [
              type: :any,
              required: true,
              doc: """
              Identifies the client. Any term: it is a key in
              `ConduitMcp.Client.Registry`, never an atom-registered name, so
              `{MyApp.GitHub, tenant_id}` or `{__MODULE__, make_ref()}` work.
              Every `ConduitMcp.Client` function takes it.
              """
            ],
            server_id: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The operator-assigned id of the server, stamped on every
              `ConduitMcp.Client.Tool`, `Resource` and `Prompt` this client
              returns. Defaults to `:name` when it is a string, else
              `inspect(name)`.
              """
            ],
            transport: [
              type: {:custom, __MODULE__, :validate_transport, []},
              required: true,
              doc: """
              `{module, opts}`: a module implementing
              `ConduitMcp.Client.Transport` and its options, for example
              `{ConduitMcp.Client.Transport.InProcess, server: MyServer}`.
              """
            ],
            protocol: [
              type: {:custom, __MODULE__, :validate_protocol, []},
              default: :auto,
              doc: """
              Which protocol era to speak. `:auto` probes `server/discover`
              and falls back to `initialize` only on legacy evidence (see
              `ConduitMcp.Client.Negotiation.classify_probe/3`). `:modern`
              and `:legacy` skip the probe; a version string
              (`"2026-07-28"`, `"2025-11-25"`, `"2025-06-18"`) pins that
              exact version.
              """
            ],
            probe_timeout: [
              type: :pos_integer,
              doc: """
              How long `protocol: :auto` waits for the `server/discover`
              probe, in milliseconds. Defaults by transport kind: 5 000 for
              `:http`, 3 000 otherwise.
              """
            ],
            prior: [
              type: {:in, [nil, :modern, :legacy]},
              default: nil,
              doc: """
              A previously observed era (for example a cached `era/1`).
              `:legacy` skips the probe and starts with `initialize`; if
              that is refused, the next attempt probes again. `:modern`
              changes nothing, since `server/discover` is the modern
              handshake.
              """
            ],
            handler: [
              type: {:custom, __MODULE__, :validate_handler, []},
              default: nil,
              doc: """
              A module implementing `ConduitMcp.Client.Handler`. Its callbacks
              decide the advertised client capabilities
              (`ConduitMcp.Client.Negotiation.client_capabilities/2`);
              without one the client advertises `{}`.
              """
            ],
            client_info: [
              type: {:custom, __MODULE__, :validate_client_info, []},
              doc: """
              The `Implementation` sent as `clientInfo`: a string-keyed map
              with at least `"name"` and `"version"`. Defaults to
              `%{"name" => "conduit_mcp", "version" => <library version>}`.
              """
            ],
            request_timeout: [
              type: :pos_integer,
              default: 60_000,
              doc: """
              Default deadline of each request, in milliseconds, and of the
              connect and handshake steps. A request's `:timeout` overrides
              it.
              """
            ],
            max_total_timeout: [
              type: :pos_integer,
              default: 300_000,
              doc: """
              With `reset_timeout_on_progress: true`, progress notifications
              push a request's deadline forward, but never past this many
              milliseconds after it was sent.
              """
            ],
            max_in_flight: [
              type: :pos_integer,
              default: 64,
              doc: """
              Requests sent and not yet answered. One more is refused at
              once with `%ConduitMcp.Client.Error{kind: :overloaded}`.
              """
            ],
            max_queued: [
              type: :pos_integer,
              default: 128,
              doc: """
              Requests waiting for the connection to become ready. One more
              is refused with `kind: :overloaded`.
              """
            ],
            backoff: [
              type: {:fun, 1},
              default: &Backoff.full_jitter/1,
              doc: """
              `fn attempt -> milliseconds end`: the delay before reconnect
              attempt `attempt` (1, 2, …). Defaults to
              `ConduitMcp.Client.Backoff.full_jitter/1`. It runs in the
              connection process, so it must be pure and fast; one that
              raises or returns anything but a non-negative integer is
              replaced by `full_jitter/1` for that attempt, with a warning.
              """
            ],
            max_reconnects: [
              type: {:or, [:non_neg_integer, {:in, [:infinity]}]},
              default: :infinity,
              doc: """
              Consecutive failed reconnect attempts before giving up. The
              count resets once the connection has stayed ready for
              `:stable_after`.
              """
            ],
            on_give_up: [
              type: {:in, [:stay, :stop]},
              default: :stay,
              doc: """
              After `:max_reconnects`: `:stay` keeps the connection alive in
              the `:closed` state (so `status/1` explains why, and
              `reconnect/1` can retry); `:stop` exits so a supervisor
              restarts it.
              """
            ],
            stable_after: [
              type: :pos_integer,
              default: 30_000,
              doc: """
              Milliseconds the connection must stay ready before the
              reconnect attempt count resets.
              """
            ],
            health_check_interval: [
              type: {:or, [:pos_integer, nil]},
              default: nil,
              doc: """
              When set, a ready connection checks the server every this many
              milliseconds (legacy `ping`, modern `server/discover`); two
              unanswered checks in a row restart the transport.
              """
            ],
            assigns: [
              type: :map,
              default: %{},
              doc: """
              Host data passed to `ConduitMcp.Client.Handler` callbacks as
              `ctx.assigns` when a server request is not tied to a call
              (a call's own `:assigns` option wins for requests tied to it).
              """
            ],
            handler_timeout: [
              type: :keyword_list,
              default: [],
              keys: [
                sampling: [type: :pos_integer, default: 60_000],
                elicitation: [type: :pos_integer, default: 300_000],
                roots: [type: :pos_integer, default: 60_000]
              ],
              doc: """
              Milliseconds a legacy server-to-client request may run in its
              handler task before it is killed and answered `-32603`, per
              method. Modern input requests run in the caller and are bounded
              by the call.
              """
            ],
            max_server_requests: [
              type: :pos_integer,
              default: 8,
              doc: """
              Legacy server-to-client requests handled at once; one more is
              answered `-32000` (busy) without running the handler.
              """
            ],
            input_rate_limit: [
              type: :keyword_list,
              default: [],
              keys: [
                per_second: [type: :pos_integer, default: 10],
                burst: [type: :pos_integer, default: 20]
              ],
              doc: """
              The per-server budget of input requests (sampling, elicitation,
              roots) in both eras. Over it, sampling is refused with the
              sampling `:rejection_code` and the others with `-32000`.
              """
            ],
            log_rate_limit: [
              type: :keyword_list,
              default: [],
              keys: [
                per_second: [type: :pos_integer, default: 50],
                burst: [type: :pos_integer, default: 100]
              ],
              doc: """
              The per-connection budget of `notifications/message` log entries
              from the server. Over it, entries are dropped before they reach
              subscribers or `handle_log/3`, and each drop emits
              `[:conduit_mcp, :client, :log, :dropped]`.
              """
            ],
            sampling: [
              type: :keyword_list,
              default: [],
              keys: [
                max_tokens: [type: :pos_integer, default: 4_096],
                context: [type: :boolean, default: false],
                tools: [type: :boolean, default: false],
                allow_idle: [type: :boolean, default: false],
                max_tool_iterations: [type: :pos_integer, default: 5],
                rejection_code: [type: :integer, default: -1]
              ],
              doc: """
              Safety settings for `sampling/createMessage` (used only when the
              handler implements `handle_sampling/2`). `:max_tokens` clamps the
              server's `maxTokens`. `:context` declares `sampling.context`
              and lets `includeContext` through; otherwise it is coerced to
              `"none"`. `:tools` declares `sampling.tools`. `:allow_idle`
              accepts legacy sampling requests that arrive while no call is in
              flight (refused by default). `:max_tool_iterations` bounds a
              sampling tool loop: a request whose `messages` already hold
              more assistant `tool_use` turns than this is refused. Refusals
              use `:rejection_code`.
              """
            ],
            elicitation: [
              type: :keyword_list,
              default: [],
              keys: [
                origin: [type: {:or, [:string, nil]}, default: nil]
              ],
              doc: """
              `:origin` - the server's origin (`"https://host[:port]"`) that a
              URL-mode elicitation URL is compared with, for transports that do
              not report one. The handler gets `origin_mismatch?: true` for any
              other origin, and when no origin is known.
              """
            ],
            roots: [
              type: :keyword_list,
              default: [],
              keys: [
                list_changed: [type: :boolean, default: true]
              ],
              doc: """
              `:list_changed` - declare `roots.listChanged` to legacy servers
              (the host announces changes with
              `ConduitMcp.Client.notify_roots_changed/1`). Used only when the
              handler implements `list_roots/1`.
              """
            ],
            max_cache_ttl: [
              type: :pos_integer,
              default: 3_600_000,
              doc: """
              The longest a cached list (`ConduitMcp.Client.Cache`) is served
              without asking the server again, whatever its `ttlMs` hint says.
              """
            ],
            policy: [
              type: {:custom, __MODULE__, :validate_policy, []},
              default: nil,
              doc: """
              Authorizes tool calls (`ConduitMcp.Client.Policy`): the
              `ConduitMcp.Client.Policy.compile/1` options, a compiled
              policy, or `{:named, name}` to read the policy stored with
              `ConduitMcp.Client.Policy.update/2` at each call (a missing
              one denies). `nil` (the default) means no authorization: the
              client sends what it is asked to (R6). Setting it routes
              `call_tool/4` through `ConduitMcp.Client.Pipeline`.
              """
            ],
            on_ask: [
              type: {:or, [{:fun, 2}, {:tuple, [:atom, :atom]}, nil]},
              default: nil,
              doc: """
              The approver for calls the policy decides `:ask`:
              `fun.(%ConduitMcp.Client.ToolCall{}, ctx)` or `{Module,
              :function}`, returning `{:allow, :once | :always}`,
              `{:deny, reason}` or `{:deny, reason, :halt}` (see
              `ConduitMcp.Client.Pipeline`). Without one, `:ask` denies.
              """
            ],
            ask_timeout: [
              type: :pos_integer,
              default: 60_000,
              doc: "Milliseconds `:on_ask` may take; after that the call is denied."
            ],
            grant_ttl: [
              type: :pos_integer,
              default: 86_400_000,
              doc: """
              How long an `{:allow, :always}` answer is remembered, in
              milliseconds (`ConduitMcp.Client.Grants`).
              """
            ],
            approved_fingerprints: [
              type: {:custom, __MODULE__, :validate_approved_fingerprints, []},
              default: :first_listing,
              doc: """
              The tool definitions the policy's `pin_tools` and
              `allow_new_tools` treat as approved: `:first_listing` records
              the fingerprints of the first full tool list the client reads;
              a map of tool name to `ConduitMcp.Client.Fingerprint` pins
              exactly those.
              """
            ],
            hooks: [
              type: {:custom, __MODULE__, :validate_hooks, []},
              default: [],
              doc: """
              Pre-call, post-call, failure, listing, resource and prompt
              hooks; see `ConduitMcp.Client.Hooks`.
              """
            ],
            hook_timeout: [
              type: :pos_integer,
              default: 5_000,
              doc: "Default milliseconds a hook may run before it fails (closed)."
            ],
            tools: [
              type: {:custom, __MODULE__, :validate_tool_filter, []},
              default: nil,
              doc: """
              Which tools are visible at all: `[include: [...], exclude:
              [...]]` (`ConduitMcp.Client.ToolFilter`). Hidden tools are left
              out of every tool list and calling one fails with
              `kind: :not_found`.
              """
            ],
            validate: [
              type: :keyword_list,
              default: [],
              keys: [
                arguments: [type: :boolean, default: false],
                structured_content: [type: :boolean, default: false],
                validator: [type: :atom, default: ConduitMcp.Client.SchemaValidator.JSV]
              ],
              doc: """
              JSON Schema validation of call arguments (`inputSchema`) and
              of `structuredContent` (`outputSchema`); see
              `ConduitMcp.Client.SchemaValidator`. The default validator
              needs the optional `:jsv` dependency: asking for validation
              without it raises `ConduitMcp.OptionalDependencyError` here.
              """
            ],
            trusted: [
              type: :boolean,
              default: false,
              doc: """
              Trust this server's tool annotations in policy annotation
              rules (PO-8) and its `instructions` in
              `ConduitMcp.Client.instructions_for_llm/1`.
              """
            ],
            max_result_bytes_for_llm: [
              type: :pos_integer,
              default: 102_400,
              doc: """
              The cap on a tool result shaped for a model (`shape: :llm`,
              see `ConduitMcp.Client.Pipeline`).
              """
            ],
            include_instructions: [
              type: :boolean,
              default: false,
              doc: """
              Whether `ConduitMcp.Client.instructions_for_llm/1` returns the
              server's `instructions` (PI-1). Off by default.
              """
            ],
            clock: [
              type: {:or, [{:fun, 0}, nil]},
              default: nil,
              doc: """
              `fn -> unix_milliseconds end` used for grant expiry (default
              the system clock); for tests.
              """
            ],
            telemetry: [
              type: :keyword_list,
              default: [],
              keys: @telemetry_keys,
              doc: """
              Telemetry settings. Client events carry allowlisted metadata
              only (see `ConduitMcp.Telemetry`); payload capture is the one
              opt-in exception.
              """
            ]
          )

  @moduledoc """
  The validated options of a `ConduitMcp.Client`.

  `ConduitMcp.Client.child_spec/1` and `ConduitMcp.Client.start_link/1` run
  `new!/1`, so a misspelled or invalid option raises an `ArgumentError`
  naming the key when the client starts, never at the first request.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @governance_keys [
    :policy,
    :on_ask,
    :ask_timeout,
    :grant_ttl,
    :approved_fingerprints,
    :hooks,
    :hook_timeout,
    :tools,
    :validate,
    :trusted,
    :max_result_bytes_for_llm,
    :include_instructions,
    :clock
  ]

  @enforce_keys [:name, :server_id, :transport, :protocol, :probe_timeout, :client_info]
  defstruct [
    :name,
    :server_id,
    :transport,
    :protocol,
    :probe_timeout,
    :prior,
    :handler,
    :client_info,
    :request_timeout,
    :max_total_timeout,
    :max_in_flight,
    :max_queued,
    :backoff,
    :max_reconnects,
    :on_give_up,
    :stable_after,
    :health_check_interval,
    :assigns,
    :handler_timeout,
    :max_server_requests,
    :input_rate_limit,
    :log_rate_limit,
    :sampling,
    :elicitation,
    :roots,
    :max_cache_ttl,
    :governance,
    # The client capabilities per era, derived from the handler once here so
    # the connection never calls handler code to build them.
    :capabilities,
    # `false`, or `%{redact: fun, max_bytes: n}` (`:telemetry
    # :capture_payloads`).
    :capture_payloads
  ]

  @type protocol :: :auto | :modern | :legacy | String.t()

  @type t :: %__MODULE__{
          name: term(),
          server_id: String.t(),
          transport: {module(), keyword()},
          protocol: protocol(),
          probe_timeout: pos_integer(),
          prior: :modern | :legacy | nil,
          handler: module() | nil,
          client_info: %{required(String.t()) => term()},
          request_timeout: pos_integer(),
          max_total_timeout: pos_integer(),
          max_in_flight: pos_integer(),
          max_queued: pos_integer(),
          backoff: (pos_integer() -> non_neg_integer()),
          max_reconnects: non_neg_integer() | :infinity,
          on_give_up: :stay | :stop,
          stable_after: pos_integer(),
          health_check_interval: pos_integer() | nil,
          assigns: map(),
          handler_timeout: keyword(),
          max_server_requests: pos_integer(),
          input_rate_limit: keyword(),
          log_rate_limit: keyword(),
          sampling: keyword(),
          elicitation: keyword(),
          roots: keyword(),
          max_cache_ttl: pos_integer(),
          governance: struct(),
          capabilities: %{modern: map(), legacy: map()},
          capture_payloads: false | %{redact: (term() -> term()), max_bytes: pos_integer()}
        }

  @doc """
  Validates `opts` and returns the config; raises `ArgumentError` naming the
  offending key. A `%Config{}` is returned unchanged.

  The governance options (`:policy` through `:clock` above) are compiled
  into the `governance` field.

  ## Example

      iex> config =
      ...>   ConduitMcp.Client.Config.new!(
      ...>     name: :docs,
      ...>     transport: {ConduitMcp.Client.Transport.InProcess, server: ConduitMcp.TestServer}
      ...>   )
      iex> {config.protocol, config.probe_timeout, config.max_in_flight}
      {:auto, 3000, 64}
  """
  @spec new!(keyword() | t()) :: t()
  def new!(%__MODULE__{} = config), do: config

  def new!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, valid} ->
        {transport, _transport_opts} = valid[:transport]
        {governance, valid} = Keyword.split(valid, @governance_keys)
        {telemetry, valid} = Keyword.pop!(valid, :telemetry)
        server_id = valid[:server_id] || default_server_id(valid[:name])

        struct!(
          __MODULE__,
          valid
          |> Keyword.put(:server_id, server_id)
          |> Keyword.put_new_lazy(:probe_timeout, fn -> default_probe_timeout(transport) end)
          |> Keyword.put_new_lazy(:client_info, &default_client_info/0)
          |> Keyword.put(:capture_payloads, telemetry[:capture_payloads])
          |> Keyword.put(:capabilities, %{
            modern: capabilities(valid, :modern),
            legacy: capabilities(valid, :legacy)
          })
          |> Keyword.put(
            :governance,
            ConduitMcp.Client.Governance.new(
              valid[:name],
              server_id,
              Keyword.update!(governance, :validate, &validator!/1)
            )
          )
        )

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ConduitMcp.Client option: " <> Exception.message(error)
    end
  end

  def new!(other) do
    raise ArgumentError,
          "ConduitMcp.Client options must be a keyword list, got: #{inspect(other)}"
  end

  # `roots.listChanged` (legacy only) is promised when configured: the host
  # announces changes with `ConduitMcp.Client.notify_roots_changed/1`.
  defp capabilities(valid, era) do
    Negotiation.client_capabilities(valid[:handler],
      era: era,
      sampling_tools: valid[:sampling][:tools],
      sampling_context: valid[:sampling][:context],
      roots_list_changed: valid[:roots][:list_changed]
    )
  end

  defp default_server_id(name) when is_binary(name), do: name
  defp default_server_id(name), do: inspect(name)

  defp default_probe_timeout(transport) do
    if transport.kind() == :http, do: 5_000, else: 3_000
  end

  defp default_client_info do
    %{"name" => "conduit_mcp", "version" => to_string(Application.spec(:conduit_mcp, :vsn))}
  end

  @jsv_validator ConduitMcp.Client.SchemaValidator.JSV

  # Validation needs its validator at start, never per request: the default
  # one only exists when the optional `:jsv` dependency was compiled in.
  defp validator!(opts) do
    validate = Map.new(opts)

    cond do
      not (validate.arguments or validate.structured_content) ->
        validate

      validate.validator == @jsv_validator ->
        ConduitMcp.OptionalDeps.jsv!()
        validate

      Code.ensure_loaded?(validate.validator) and
        function_exported?(validate.validator, :build, 2) and
          function_exported?(validate.validator, :validate, 2) ->
        validate

      true ->
        raise ArgumentError,
              "invalid ConduitMcp.Client option: :validate :validator " <>
                "#{inspect(validate.validator)} does not implement ConduitMcp.Client.SchemaValidator"
    end
  end

  @doc false
  # NimbleOptions `{:custom, ...}` validator for `:transport`. A transport
  # implementing the optional `validate_options/1` checks its own options
  # here, so they fail at `child_spec/1` naming the key.
  @spec validate_transport(term()) :: {:ok, {module(), keyword()}} | {:error, String.t()}
  def validate_transport({module, opts} = transport) when is_atom(module) and is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected the transport options to be a keyword list, got: #{inspect(opts)}"}

      not Code.ensure_loaded?(module) ->
        {:error, "#{inspect(module)} is not an available module"}

      not (function_exported?(module, :init, 2) and function_exported?(module, :kind, 0)) ->
        {:error, "#{inspect(module)} does not implement ConduitMcp.Client.Transport"}

      function_exported?(module, :validate_options, 1) ->
        case module.validate_options(opts) do
          {:ok, opts} -> {:ok, {module, opts}}
          {:error, message} -> {:error, "invalid #{inspect(module)} options: " <> message}
        end

      true ->
        {:ok, transport}
    end
  end

  def validate_transport(other),
    do: {:error, "expected {module, keyword_opts}, got: #{inspect(other)}"}

  @doc false
  @spec validate_protocol(term()) :: {:ok, protocol()} | {:error, String.t()}
  def validate_protocol(protocol) when protocol in @protocols, do: {:ok, protocol}

  def validate_protocol(version) when is_binary(version) do
    if version in Negotiation.client_versions(),
      do: {:ok, version},
      else:
        {:error,
         "expected :auto, :modern, :legacy or one of " <>
           "#{inspect(Negotiation.client_versions())}, got: #{inspect(version)}"}
  end

  def validate_protocol(other),
    do:
      {:error,
       "expected :auto, :modern, :legacy or a protocol version string, got: #{inspect(other)}"}

  @doc false
  @spec validate_handler(term()) :: {:ok, module() | nil} | {:error, String.t()}
  def validate_handler(nil), do: {:ok, nil}

  def validate_handler(handler) when is_atom(handler) do
    # A bad `elicitation_modes/0` fails here, naming the key; `new!/1`
    # stores the capabilities built from it.
    _ = Negotiation.client_capabilities(handler)
    {:ok, handler}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def validate_handler(other),
    do: {:error, "expected a ConduitMcp.Client.Handler module, got: #{inspect(other)}"}

  @doc false
  @spec validate_client_info(term()) :: {:ok, map()} | {:error, String.t()}
  def validate_client_info(%{"name" => name, "version" => version} = info)
      when is_binary(name) and is_binary(version),
      do: {:ok, info}

  def validate_client_info(other),
    do: {:error, ~s(expected a map with string "name" and "version" keys, got: #{inspect(other)})}

  @doc false
  @spec validate_policy(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_policy(nil), do: {:ok, nil}
  def validate_policy({:named, _name} = named), do: {:ok, named}
  def validate_policy(%ConduitMcp.Client.Policy{} = policy), do: {:ok, policy}

  def validate_policy(opts) when is_list(opts) do
    {:ok, ConduitMcp.Client.Policy.compile(opts)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def validate_policy(other),
    do:
      {:error,
       "expected policy options, a compiled policy or {:named, name}, got: #{inspect(other)}"}

  @doc false
  @spec validate_tool_filter(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_tool_filter(nil), do: {:ok, nil}
  def validate_tool_filter(%ConduitMcp.Client.ToolFilter{} = filter), do: {:ok, filter}

  def validate_tool_filter(opts) when is_list(opts) do
    {:ok, ConduitMcp.Client.ToolFilter.compile(opts)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def validate_tool_filter(other),
    do: {:error, "expected [include: [...], exclude: [...]], got: #{inspect(other)}"}

  @doc false
  @spec validate_hooks(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_hooks(hooks) do
    {:ok, ConduitMcp.Client.Hooks.compile(hooks)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc false
  @spec validate_approved_fingerprints(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_approved_fingerprints(:first_listing), do: {:ok, :first_listing}

  def validate_approved_fingerprints(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(map, fn {tool, fingerprint} -> is_binary(tool) and is_binary(fingerprint) end),
      do: {:ok, map},
      else: {:error, "expected a map of tool name to fingerprint (strings), got: #{inspect(map)}"}
  end

  def validate_approved_fingerprints(other),
    do:
      {:error,
       "expected :first_listing or a map of tool name to fingerprint, got: #{inspect(other)}"}

  @doc false
  # NimbleOptions `{:custom, ...}` validator for `:telemetry
  # :capture_payloads`. Redaction is mandatory, so `true` is refused.
  @spec validate_capture_payloads(term()) ::
          {:ok, false | %{redact: (term() -> term()), max_bytes: pos_integer()}}
          | {:error, String.t()}
  def validate_capture_payloads(false), do: {:ok, false}

  def validate_capture_payloads(true),
    do:
      {:error,
       "true is not accepted: payload capture requires a :redact function " <>
         "(capture_payloads: [redact: &MyApp.redact/1])"}

  def validate_capture_payloads(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @capture_schema) do
      {:ok, valid} -> {:ok, Map.new(valid)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def validate_capture_payloads(other),
    do:
      {:error,
       "expected false or [redact: fun/1, max_bytes: pos_integer], got: #{inspect(other)}"}

  @doc false
  # Validates a `:telemetry` keyword list without converting it, for a hub's
  # defaults (each server's client validates the merged options again).
  @spec validate_telemetry(term()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_telemetry(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @telemetry_schema) do
      {:ok, _valid} -> {:ok, opts}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def validate_telemetry(other),
    do: {:error, "expected a keyword list, got: #{inspect(other)}"}
end
