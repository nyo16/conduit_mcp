defmodule ConduitMcp.Client.Connection.Authorize do
  @moduledoc false

  # OAuth inside the connection (`auth: {:oauth, ...}` on the Streamable
  # HTTP transport): the `:authorizing` state and step-up. The connection
  # never does OAuth work itself - no HTTP, no token store, no user code.
  # It runs `ConduitMcp.Client.OAuth.Session` functions in tasks under the
  # client's `Task.Supervisor` and acts on their results.
  #
  # ## A 401
  #
  # The refused request is parked (a caller's stays pending, its deadline
  # still running; a handshake request is dropped) and the connection
  # enters `:authorizing`, recording where it came from (`:ready`, or the
  # handshake). One check task runs `Session.check/2`: discovery if needed,
  # then a token newer than the refused one, a refresh, or a new
  # client-credentials token. Requests arriving meanwhile wait in
  # `waiting`; requests still in flight that come back 401 are parked too.
  #
  #   * A token: the session (with what discovery found) goes to the
  #     transport, parked requests are sent again with the same ids
  #     (`Requests.resend/2`), the connection returns to `:ready` or
  #     restarts the handshake, and waiting requests are replayed.
  #   * `:authorization_required`: parked and waiting requests fail with
  #     `kind: :auth, reason: :authorization_required` and the challenge;
  #     the host's `on_authorization_required` runs in a task (once per
  #     episode). The connection stays in `:authorizing`, awaiting the host:
  #     every request that arrives starts a new check (a store read, cheap)
  #     and waits for it, so tokens the host stored with
  #     `ConduitMcp.Client.OAuth.handle_callback/3` are picked up by the
  #     next request; `ConduitMcp.Client.authorized/1` starts that check at
  #     once. Interactive authorization never blocks a request.
  #   * Any other OAuth failure: the connection closes with `kind: :auth`
  #     (a refusal such as a PRM `resource` mismatch or missing `S256`), or
  #     reconnects with backoff when the failure may be transient (metadata
  #     or token endpoint unreachable).
  #
  # ## A 403 `insufficient_scope` (step-up, OA-10)
  #
  # The scopes asked for are the union of the scopes of the current tokens
  # and the challenged ones. At most `max_step_up_attempts` per `{resource,
  # scope set}`; beyond that the request fails with `:step_up_limit`. For
  # the authorization-code flow the request fails with
  # `:authorization_required` and a challenge naming the union, and the
  # host is told; the connection stays `:ready` (other requests may well be
  # within scope). A client-credentials client requests the new token in a
  # task and sends the request again.

  alias ConduitMcp.Client.Config, as: ClientConfig
  alias ConduitMcp.Client.Connection.Credential
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Handshake
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.OAuth.Challenge
  alias ConduitMcp.Client.OAuth.Config
  alias ConduitMcp.Client.OAuth.Error, as: OAuthError
  alias ConduitMcp.Client.OAuth.Scopes
  alias ConduitMcp.Client.OAuth.Telemetry

  require Logger

  # Failures a new connection attempt may cure.
  @transient [
    :no_protected_resource_metadata,
    :no_authorization_server_metadata,
    :token_request_failed,
    :registration_failed
  ]

  defstruct [
    :mod,
    :session,
    phase: :idle,
    # ref => :check | {:step_up, [id]}
    tasks: %{},
    # where a successful check returns: :ready | :handshake
    return_to: :ready,
    # caller request ids refused with 401, waiting for the check
    parked: [],
    # `$mcp_request` messages that arrived in `:authorizing`, newest first,
    # and how many (admission stays O(1))
    waiting: [],
    waiting_count: 0,
    # the Bearer challenge of the last 401, and the fingerprint of the
    # token it refused (never the token)
    challenge: nil,
    sent: nil,
    notified?: false,
    # the scopes of the tokens last found, for the step-up union
    scopes: [],
    # step-up attempts (`ConduitMcp.Client.OAuth.Scopes.attempts()`)
    step_ups: %{}
  ]

  @type t :: %__MODULE__{}

  @type result :: :gen_statem.event_handler_result(atom())

  @doc """
  The OAuth state for a client whose transport options carry
  `auth: {:oauth, %ConduitMcp.Client.OAuth.Config{}}`, or `nil`.
  """
  @spec new(ClientConfig.t()) :: t() | nil
  def new(%ClientConfig{transport: {_transport, opts}} = config) do
    case Keyword.get(opts, :auth) do
      {:oauth, %Config{} = oauth} ->
        mod = ConduitMcp.OptionalDeps.oauth_client!()
        oauth = %{oauth | client: config.name, server_id: config.server_id}
        %__MODULE__{mod: mod, session: mod.new(oauth)}

      _other ->
        nil
    end
  end

  @doc """
  Hands the session to the transport (after every transport `init/2`), and
  records the identity of the credentials sent from now on, which keys the
  private cached results (HT-11).
  """
  @spec push(Data.t()) :: Data.t()
  def push(%Data{} = data), do: data |> hand_over() |> Credential.sync()

  defp hand_over(%Data{auth: %__MODULE__{session: session}, tstate: tstate} = data)
       when tstate != nil do
    if function_exported?(data.transport, :set_auth, 2),
      do: %{data | tstate: data.transport.set_auth(tstate, session)},
      else: data
  end

  defp hand_over(data), do: data

  # --- a refused request -------------------------------------------------------

  @doc """
  `{:unauthorized, id, info}` from the transport. `:pass` when OAuth does
  not handle it (not configured, a 403 that is not a step-up, an internal
  request other than the handshake): the connection then fails the request
  as before.
  """
  @spec unauthorized(pos_integer(), map(), atom(), Data.t()) :: result() | :pass
  def unauthorized(_id, _info, _state, %Data{auth: nil}), do: :pass

  def unauthorized(id, %{status: 401} = info, state, data) do
    cond do
      Map.has_key?(data.pending, id) ->
        refused(id, info, state, data)

      Map.get(data.internal, id) in [:discover, :initialize] and
          state in [:discovering, :initializing] ->
        data = %{data | internal: Map.delete(data.internal, id), handshake: nil}
        refused(nil, info, state, data)

      true ->
        :pass
    end
  end

  def unauthorized(id, %{status: 403, challenges: challenges}, _state, data) do
    challenge = Challenge.bearer(challenges)

    if challenge != nil and Challenge.insufficient_scope?(challenge) and
         Map.has_key?(data.pending, id),
       do: step_up(id, challenge, data),
       else: :pass
  end

  def unauthorized(_id, _info, _state, _data), do: :pass

  defp refused(id, info, state, %Data{auth: auth} = data) do
    challenge = Challenge.bearer(Map.get(info, :challenges, [])) || auth.challenge

    cond do
      # Awaiting the host: an older request coming back 401 fails at once.
      state == :authorizing and auth.phase == :awaiting and id != nil ->
        {data, actions} = fail_ids([id], required_error(auth), data)
        {:keep_state, data, actions}

      state == :authorizing ->
        auth = %{auth | parked: park(auth.parked, id), challenge: challenge}
        auth = if auth.phase == :checking, do: auth, else: start_check(auth, data)
        {:keep_state, %{data | auth: auth}}

      true ->
        auth = %{
          auth
          | parked: park(auth.parked, id),
            challenge: challenge,
            sent: Map.get(info, :sent),
            return_to: if(state == :ready, do: :ready, else: :handshake)
        }

        {:next_state, :authorizing, %{data | auth: start_check(auth, data)}}
    end
  end

  defp park(parked, nil), do: parked
  defp park(parked, id), do: parked ++ [id]

  # `fresh?` discovers again first (the host's explicit signal: it may have
  # authorized with an authorization server the server named since).
  defp start_check(auth, data, fresh? \\ false) do
    info = %{challenge: auth.challenge, sent: auth.sent}
    session = if fresh?, do: %{auth.session | context: nil}, else: auth.session
    task = Task.Supervisor.async_nolink(data.task_sup, auth.mod, :check, [session, info])
    %{auth | phase: :checking, tasks: Map.put(auth.tasks, task.ref, :check)}
  end

  # --- requests while authorizing ------------------------------------------

  @doc """
  A request in `:authorizing`: it waits for the check (one is started if
  the connection is awaiting the host).
  """
  @spec admit(tuple(), Data.t()) :: result()
  def admit({_tag, mref, _caller, _op, _params, _opts} = request, %Data{auth: auth} = data) do
    if auth.waiting_count >= data.config.max_queued do
      Requests.reply(mref, {:error, Error.new(:overloaded, :max_queued)})
      :keep_state_and_data
    else
      auth = %{auth | waiting: [request | auth.waiting], waiting_count: auth.waiting_count + 1}
      auth = if auth.phase == :awaiting, do: start_check(auth, data), else: auth
      {:keep_state, %{data | auth: auth}}
    end
  end

  @doc """
  `ConduitMcp.Client.authorized/1`: the host stored tokens; check now if
  the connection is awaiting them.
  """
  @spec authorized(reference(), atom(), Data.t()) :: result()
  def authorized(mref, _state, %Data{auth: nil}) do
    Requests.reply(mref, {:error, Error.new(:auth, :oauth_not_configured)})
    :keep_state_and_data
  end

  def authorized(mref, state, %Data{auth: auth} = data) do
    Requests.reply(mref, :ok)

    if state == :authorizing and auth.phase == :awaiting,
      do: {:keep_state, %{data | auth: start_check(auth, data, true)}},
      else: :keep_state_and_data
  end

  @doc "The control call behind `ConduitMcp.Client.OAuth` given a client name."
  @spec session(reference(), Data.t()) :: result()
  def session(mref, %Data{auth: nil}) do
    Requests.reply(mref, {:error, Error.new(:auth, :oauth_not_configured)})
    :keep_state_and_data
  end

  def session(mref, %Data{auth: auth}) do
    Requests.reply(mref, {:ok, auth.session})
    :keep_state_and_data
  end

  # --- task results ----------------------------------------------------------

  @doc "Whether `ref` is one of this connection's OAuth tasks."
  @spec task?(Data.t(), reference()) :: boolean()
  def task?(%Data{auth: %__MODULE__{tasks: tasks}}, ref), do: Map.has_key?(tasks, ref)
  def task?(_data, _ref), do: false

  @doc "An OAuth task answered."
  @spec task_result(reference(), term(), atom(), Data.t()) :: result()
  def task_result(ref, answer, state, %Data{auth: auth} = data) do
    Process.demonitor(ref, [:flush])
    {kind, tasks} = Map.pop(auth.tasks, ref)
    data = %{data | auth: %{auth | tasks: tasks}}

    case kind do
      :check -> checked(answer, state, data)
      {:step_up, ids} -> stepped_up(answer, ids, data)
    end
  end

  @doc "An OAuth task exited without answering."
  @spec task_down(reference(), atom(), Data.t()) :: result()
  def task_down(ref, state, data) do
    error = OAuthError.new(:token_request_failed, %{reason: :crashed})
    task_result(ref, {:error, error, data.auth.session}, state, data)
  end

  defp checked({:ok, session, scopes}, state, %Data{auth: auth} = data) do
    auth = %{auth | session: session, scopes: scopes, phase: :idle, notified?: false}
    data = push(%{data | auth: auth})
    {data, resent} = resend(auth.parked, data)
    replay = auth.waiting |> Enum.reverse() |> Enum.map(&{:next_event, :info, &1})
    data = %{data | auth: %{data.auth | parked: [], waiting: [], waiting_count: 0}}

    cond do
      state != :authorizing -> {:keep_state, data, resent ++ replay}
      auth.return_to == :ready -> {:next_state, :ready, data, resent ++ replay}
      true -> data |> Handshake.connected() |> add_actions(resent ++ replay)
    end
  end

  defp checked({:authorization_required, session}, _state, %Data{auth: auth} = data) do
    auth = %{auth | session: session, phase: :awaiting}
    error = required_error(auth)
    {data, actions} = fail_ids(auth.parked, error, %{data | auth: auth})
    auth.waiting |> Enum.reverse() |> Enum.each(&reply_error(&1, error))
    data = %{data | auth: %{data.auth | parked: [], waiting: [], waiting_count: 0}}
    data = if auth.notified?, do: data, else: notify(data, auth.challenge, :unauthorized)
    {:keep_state, data, actions}
  end

  defp checked({:error, %OAuthError{} = oauth_error, session}, _state, %Data{auth: auth} = data) do
    error = Error.new(:auth, oauth_error.reason, oauth_error)
    auth.waiting |> Enum.reverse() |> Enum.each(&reply_error(&1, error))
    auth = %{auth | session: session, phase: :idle, parked: [], waiting: [], waiting_count: 0}
    data = %{data | auth: auth}

    if oauth_error.reason in @transient,
      do: Handshake.reconnect(error, data),
      else: Handshake.close(error, data)
  end

  defp resend(ids, data) do
    Enum.reduce(ids, {data, []}, fn id, {data, actions} ->
      {data, more} = Requests.resend(data, id)
      {data, actions ++ more}
    end)
  end

  defp add_actions({:next_state, state, data, actions}, more),
    do: {:next_state, state, data, actions ++ more}

  defp add_actions(other, _more), do: other

  # --- step-up ------------------------------------------------------------------

  defp step_up(id, challenge, %Data{auth: auth} = data) do
    config = auth.session.config
    resource = resource(auth)
    scopes = Scopes.union(auth.scopes, Challenge.scopes(challenge))
    meta = Telemetry.base(config)

    Telemetry.span(:step_up, meta, fn ->
      if Scopes.step_up_allowed?(auth.step_ups, resource, scopes, config.max_step_up_attempts) do
        auth = %{auth | step_ups: Scopes.record_step_up(auth.step_ups, resource, scopes)}
        result = start_step_up(id, challenge, scopes, %{data | auth: auth})
        {result, %{}}
      else
        error = Error.new(:auth, :step_up_limit, %{challenge: challenge})
        {data, actions} = fail_ids([id], error, data)
        {{:keep_state, data, actions}, %{status: :error, reason: :step_up_limit}}
      end
    end)
  end

  defp start_step_up(
         id,
         _challenge,
         scopes,
         %Data{auth: %{session: %{config: %{grant: :client_credentials}}} = auth} = data
       ) do
    task = Task.Supervisor.async_nolink(data.task_sup, auth.mod, :step_up, [auth.session, scopes])
    auth = %{auth | tasks: Map.put(auth.tasks, task.ref, {:step_up, [id]})}
    {:keep_state, %{data | auth: auth}}
  end

  defp start_step_up(id, challenge, scopes, %Data{auth: auth} = data) do
    params =
      challenge.params
      |> Map.put("scope", Scopes.join(scopes))
      |> Map.put("error", "insufficient_scope")

    challenge = %Challenge{scheme: "bearer", params: params}
    error = Error.new(:auth, :authorization_required, %{challenge: challenge})
    {data, actions} = fail_ids([id], error, %{data | auth: %{auth | challenge: challenge}})
    {:keep_state, notify(data, challenge, :step_up), actions}
  end

  defp stepped_up({:ok, session, scopes}, ids, %Data{auth: auth} = data) do
    data = push(%{data | auth: %{auth | session: session, scopes: scopes}})
    {data, actions} = resend(ids, data)
    {:keep_state, data, actions}
  end

  defp stepped_up({:error, %OAuthError{} = oauth_error, session}, ids, %Data{auth: auth} = data) do
    error = Error.new(:auth, oauth_error.reason, oauth_error)
    {data, actions} = fail_ids(ids, error, %{data | auth: %{auth | session: session}})
    {:keep_state, data, actions}
  end

  defp resource(%__MODULE__{session: %{context: %{resource: resource}}}), do: resource
  defp resource(%__MODULE__{session: %{config: config}}), do: config.server_url

  # --- shared --------------------------------------------------------------------

  @doc """
  The connection is being torn down (reconnect, close): fail the requests
  waiting here and forget the episode. Running tasks are abandoned (their
  answers are dropped); parked requests are pending and fail with the rest.
  """
  @spec reset(Data.t(), Error.t()) :: Data.t()
  def reset(%Data{auth: %__MODULE__{} = auth} = data, error) do
    auth.waiting |> Enum.reverse() |> Enum.each(&reply_error(&1, error))
    Enum.each(Map.keys(auth.tasks), &Process.demonitor(&1, [:flush]))
    %{data | auth: %{auth | phase: :idle, tasks: %{}, parked: [], waiting: [], waiting_count: 0}}
  end

  def reset(data, _error), do: data

  defp required_error(auth) do
    Error.new(:auth, :authorization_required, %{challenge: auth.challenge || bare_challenge()})
  end

  defp bare_challenge, do: %Challenge{scheme: "bearer", params: %{}}

  defp fail_ids(ids, error, data) do
    Enum.reduce(ids, {data, []}, fn id, {data, actions} ->
      {data, more} = Requests.exchange_done(id, {:error, error}, data)
      {data, actions ++ more}
    end)
  end

  defp reply_error({_tag, mref, _caller, _op, _params, _opts}, error),
    do: Requests.reply(mref, {:error, error})

  # The host's callback runs in a task: user code never runs here.
  defp notify(%Data{auth: auth} = data, challenge, reason) do
    challenge = challenge || bare_challenge()
    config = auth.session.config
    Telemetry.authorization_required(Telemetry.base(config), reason)

    case config.on_authorization_required do
      nil ->
        :ok

      callback ->
        Task.Supervisor.start_child(data.task_sup, fn -> run_callback(callback, challenge) end)
    end

    %{data | auth: %{data.auth | notified?: true}}
  end

  defp run_callback(callback, challenge) do
    callback.(challenge)
  catch
    kind, _reason ->
      Logger.warning("MCP client on_authorization_required callback failed (#{kind})")
  end
end
