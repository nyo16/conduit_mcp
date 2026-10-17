defmodule ConduitMcp.Client.Governance do
  @moduledoc false
  # A client's governance settings (compiled by `ConduitMcp.Client.Config`
  # into its `governance` field) and its governance table.
  #
  # `ConduitMcp.Client.Governance.Owner` creates the table and registers
  # `%{table: tid, settings: %Governance{}}` under `{:governance, name}` in
  # `ConduitMcp.Client.Registry`; callers read both from there without
  # messaging any process. The table is `:protected`: only the owner writes
  # it (grants, the approval baseline, built schemas), callers read it
  # directly.
  #
  # Rows:
  #
  #   {{:grant, principal, server_id, tool, fingerprint}, expires_at}
  #   {:baseline}                                   - the baseline was recorded
  #   {{:baseline, server_id, tool}, fingerprint}
  #   {{:schema, validator, :input | :output, fingerprint}, {:ok, built} | {:error, reason}}

  alias ConduitMcp.Client.{Error, Fingerprint, Hooks, Registry, SchemaValidator, Tool}
  alias ConduitMcp.Client.Governance.Owner

  @enforce_keys [:name, :server_id]
  defstruct [
    :name,
    :server_id,
    :policy,
    :on_ask,
    :filter,
    :validate,
    ask_timeout: 60_000,
    hooks: %Hooks{},
    hook_timeout: 5_000,
    trusted: false,
    approved_fingerprints: :first_listing,
    grant_ttl: 86_400_000,
    clock: nil,
    max_result_bytes_for_llm: 102_400,
    include_instructions: false,
    enabled?: false
  ]

  @type validate :: %{arguments: boolean(), structured_content: boolean(), validator: module()}

  @type t :: %__MODULE__{
          name: term(),
          server_id: String.t(),
          policy: ConduitMcp.Client.Policy.t() | {:named, term()} | nil,
          on_ask: function() | {module(), atom()} | nil,
          filter: ConduitMcp.Client.ToolFilter.t() | nil,
          validate: validate() | nil,
          ask_timeout: pos_integer(),
          hooks: Hooks.t(),
          hook_timeout: pos_integer(),
          trusted: boolean(),
          approved_fingerprints: :first_listing | %{{String.t(), String.t()} => String.t()},
          grant_ttl: pos_integer(),
          clock: (-> integer()) | nil,
          max_result_bytes_for_llm: pos_integer(),
          include_instructions: boolean(),
          enabled?: boolean()
        }

  @typedoc "What `lookup/1` returns: the owner, its table and the settings."
  @type ref :: %{owner: pid(), table: :ets.tid(), settings: t()}

  @doc """
  Builds the settings from the validated governance options of client
  `name` (`ConduitMcp.Client.Config.new!/1`).
  """
  @spec new(term(), String.t(), keyword()) :: t()
  def new(name, server_id, opts) do
    validate =
      case Keyword.fetch!(opts, :validate) do
        %{arguments: false, structured_content: false} -> nil
        validate -> validate
      end

    approved =
      case Keyword.fetch!(opts, :approved_fingerprints) do
        :first_listing ->
          :first_listing

        map ->
          Map.new(map, fn {tool, fingerprint} -> {{server_id, tool}, fingerprint} end)
      end

    # NimbleOptions does not run custom validators on defaults (`[]`).
    hooks = Hooks.compile(Keyword.fetch!(opts, :hooks))
    policy = Keyword.fetch!(opts, :policy)
    filter = Keyword.fetch!(opts, :tools)

    %__MODULE__{
      name: name,
      server_id: server_id,
      policy: policy,
      on_ask: Keyword.fetch!(opts, :on_ask),
      filter: filter,
      validate: validate,
      ask_timeout: Keyword.fetch!(opts, :ask_timeout),
      hooks: hooks,
      hook_timeout: Keyword.fetch!(opts, :hook_timeout),
      trusted: Keyword.fetch!(opts, :trusted),
      approved_fingerprints: approved,
      grant_ttl: Keyword.fetch!(opts, :grant_ttl),
      clock: Keyword.fetch!(opts, :clock),
      max_result_bytes_for_llm: Keyword.fetch!(opts, :max_result_bytes_for_llm),
      include_instructions: Keyword.fetch!(opts, :include_instructions),
      enabled?: policy != nil or filter != nil or validate != nil or not Hooks.empty?(hooks)
    }
  end

  @doc "The client's governance owner, table and settings."
  @spec lookup(term()) :: {:ok, ref()} | {:error, Error.t()}
  def lookup(client) do
    case Registry.lookup({:governance, client}) do
      {:ok, pid, %{table: table, settings: settings}} ->
        {:ok, %{owner: pid, table: table, settings: settings}}

      _starting_or_missing ->
        {:error, Error.new(:unavailable, :not_started)}
    end
  end

  @doc "Unix time in milliseconds, from the configured clock."
  @spec now(t()) :: integer()
  def now(%__MODULE__{clock: nil}), do: System.system_time(:millisecond)
  def now(%__MODULE__{clock: clock}), do: clock.()

  # --- baseline ------------------------------------------------------------------------

  @doc """
  The approved fingerprint of the tool `key` (`{server_id, name}`) as the
  one-entry map `ConduitMcp.Client.Policy` reads (`%{}` when it has none):
  from the configured map, or from the baseline recorded from the first
  full tool list.
  """
  @spec approved(ref(), {String.t(), String.t()}) :: map()
  def approved(%{settings: %__MODULE__{approved_fingerprints: :first_listing}} = ref, key) do
    {server_id, name} = key

    case read(ref.table, {:baseline, server_id, name}) do
      [{_row, fingerprint}] -> %{key => fingerprint}
      _none -> %{}
    end
  end

  def approved(%{settings: %__MODULE__{approved_fingerprints: map}}, key),
    do: Map.take(map, [key])

  @doc "Whether a baseline is needed and not recorded yet."
  @spec needs_baseline?(ref()) :: boolean()
  def needs_baseline?(%{settings: %__MODULE__{approved_fingerprints: :first_listing}} = ref),
    do: read(ref.table, :baseline) == []

  def needs_baseline?(_ref), do: false

  @doc """
  Records `tools` (a full listing) as the approval baseline, once: later
  calls are no-ops. Only with `approved_fingerprints: :first_listing`.
  """
  @spec record_baseline(ref(), [Tool.t()]) :: :ok
  def record_baseline(ref, tools) do
    if needs_baseline?(ref) do
      baseline = for %Tool{} = tool <- tools, do: {tool.server_id, tool.name, fingerprint(tool)}
      Owner.write(ref.owner, {:put_baseline, baseline})
    end

    :ok
  end

  @doc "A tool's fingerprint (computed when the struct has none)."
  @spec fingerprint(Tool.t()) :: String.t()
  def fingerprint(%Tool{fingerprint: fingerprint}) when is_binary(fingerprint), do: fingerprint
  def fingerprint(%Tool{} = tool), do: Fingerprint.compute(tool)

  # --- schemas -------------------------------------------------------------------------

  @doc """
  The built `direction` schema of `tool` (`:input` is `inputSchema`,
  `:output` is `outputSchema`) for the configured validator: `{:ok, :none}`
  when the tool has no such schema, `{:error, reason}` when it is refused
  (`ConduitMcp.Client.SchemaValidator` bounds) or fails to build. Results
  are cached per fingerprint.
  """
  @spec schema(ref(), Tool.t(), :input | :output) :: {:ok, term()} | {:error, atom()}
  def schema(%{settings: %__MODULE__{validate: %{validator: validator}}} = ref, tool, direction) do
    case raw_schema(tool, direction) do
      nil ->
        {:ok, :none}

      raw ->
        key = {:schema, validator, direction, fingerprint(tool)}

        case read(ref.table, key) do
          [{^key, cached}] ->
            cached

          _miss ->
            built = build(validator, raw)
            Owner.write(ref.owner, {:put_schema, key, built})
            built
        end
    end
  end

  defp raw_schema(%Tool{input_schema: schema}, :input), do: schema
  defp raw_schema(%Tool{output_schema: schema}, :output), do: schema

  defp build(validator, raw) do
    with :ok <- SchemaValidator.check_bounds(raw) do
      case validator.build(raw, []) do
        {:ok, built} -> {:ok, built}
        {:error, _reason} -> {:error, :build_failed}
      end
    end
  rescue
    _error -> {:error, :build_failed}
  end

  @doc false
  @spec read(:ets.tid(), term()) :: [tuple()]
  def read(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end
end
