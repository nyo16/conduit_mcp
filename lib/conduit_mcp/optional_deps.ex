defmodule ConduitMcp.OptionalDeps do
  @moduledoc """
  Runtime availability checks for ConduitMCP's conditionally compiled modules.

  `ConduitMcp.Plugs.OAuth`, `ConduitMcp.OAuth.KeyProvider.JWKS` and
  `ConduitMcp.Client.SchemaValidator.JSV` only exist when their optional
  dependency was present when `:conduit_mcp` was compiled. Every code path
  that can reach one of them crosses an `init/1` (a plug's, or a client's
  option validation), so availability is validated there — once, at boot or
  compile time — rather than degrading into a per-request failure that is
  indistinguishable from a configuration mistake.

  The client's Streamable HTTP transport
  (`ConduitMcp.Client.Transport.StreamableHTTP`) needs `:finch`; it calls
  `finch!/0` when its options are validated and when it starts, so a build
  without Finch fails when the client starts, never on a request.

  See `ConduitMcp.OptionalDependencyError` for why adding the dependency to
  `mix.exs` is not sufficient on its own.
  """

  alias ConduitMcp.OptionalDependencyError

  @oauth_plug ConduitMcp.Plugs.OAuth
  @jwks_provider ConduitMcp.OAuth.KeyProvider.JWKS
  @jsv_validator ConduitMcp.Client.SchemaValidator.JSV
  @client_http ConduitMcp.Client.HTTP
  @oauth_session ConduitMcp.Client.OAuth.Session
  @client_assertion ConduitMcp.Client.OAuth.ClientAssertion

  @joken_deps [{:joken, "~> 2.6"}, {:jose, "~> 1.11"}]
  @req_deps [{:req, "~> 0.6.1 or ~> 0.7"}]
  @jsv_deps [{:jsv, "~> 0.26"}]
  @finch_deps [{:finch, "~> 0.21"}]

  @doc """
  Returns the client's internal HTTP module (compiled only with `:finch`),
  raising `ConduitMcp.OptionalDependencyError` naming `{:finch, "~> 0.21"}`
  when it was not compiled in.
  """
  @spec finch!() :: module()
  def finch!, do: finch!(@client_http)

  @doc false
  # The check behind `finch!/0`, taking the module so the absent case is
  # testable in a build that has Finch.
  @spec finch!(module()) :: module()
  def finch!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise OptionalDependencyError,
        feature: "The Streamable HTTP client transport",
        module: module,
        deps: @finch_deps
    end
  end

  @doc """
  Returns the OAuth plug module, raising `ConduitMcp.OptionalDependencyError`
  when it was not compiled in.
  """
  @spec oauth_plug!() :: module()
  def oauth_plug!, do: oauth_plug!(@oauth_plug)

  @doc false
  # The check behind `oauth_plug!/0`. Taking the module keeps its return
  # type `module()` rather than one literal atom, so a caller compiles
  # without an "undefined function" warning in builds without `:joken`.
  @spec oauth_plug!(module()) :: module()
  def oauth_plug!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise OptionalDependencyError,
        feature: "The :oauth auth strategy",
        module: module,
        deps: @joken_deps
    end
  end

  @doc """
  Returns `true` when the `:oauth` auth strategy is usable in this build.
  """
  @spec oauth_available?() :: boolean()
  def oauth_available?, do: Code.ensure_loaded?(@oauth_plug)

  @doc """
  Returns the JSV schema validator module
  (`ConduitMcp.Client.SchemaValidator.JSV`), raising
  `ConduitMcp.OptionalDependencyError` when it was not compiled in.

  `ConduitMcp.Client` calls it when its options are validated, if `:validate`
  asks for argument or `structuredContent` validation with the default
  validator; it is never called per request.
  """
  @spec jsv!() :: module()
  def jsv! do
    if Code.ensure_loaded?(@jsv_validator) do
      @jsv_validator
    else
      raise OptionalDependencyError,
        feature: "Client JSON Schema validation (the :validate option)",
        module: @jsv_validator,
        deps: @jsv_deps
    end
  end

  @doc """
  Returns `true` when the JSV schema validator is usable in this build.
  """
  @spec jsv_available?() :: boolean()
  def jsv_available?, do: Code.ensure_loaded?(@jsv_validator)

  @doc """
  Returns the module that runs the client's OAuth flow for a connection
  (an internal module compiled only with `:finch`), raising
  `ConduitMcp.OptionalDependencyError` naming `{:finch, "~> 0.21"}` when it
  was not compiled in. Called when a client configured with
  `auth: {:oauth, ...}` starts.
  """
  @spec oauth_client!() :: module()
  def oauth_client!, do: oauth_client!(@oauth_session)

  @doc false
  # The check behind `oauth_client!/0`. Taking the module keeps its return
  # type `module()` rather than one literal atom, so callers compile
  # without an "undefined function" warning in builds without `:finch`.
  @spec oauth_client!(module()) :: module()
  def oauth_client!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise OptionalDependencyError,
        feature: "The MCP client's OAuth support (auth: {:oauth, ...})",
        module: module,
        deps: @finch_deps
    end
  end

  @doc """
  Returns the `private_key_jwt` client-assertion signer (compiled only with
  `:jose`), raising `ConduitMcp.OptionalDependencyError` naming
  `{:jose, "~> 1.11"}` when it was not compiled in. Called when an OAuth
  configuration with a `:private_key` is validated.
  """
  @spec client_assertion!() :: module()
  def client_assertion!, do: client_assertion!(@client_assertion)

  @doc false
  # The check behind `client_assertion!/0`. Taking the module keeps its
  # return type `module()` rather than one literal atom, so callers compile
  # without an "undefined function" warning in builds without `:jose`.
  @spec client_assertion!(module()) :: module()
  def client_assertion!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise OptionalDependencyError,
        feature: "OAuth private_key_jwt client authentication (the :private_key option)",
        module: module,
        deps: [{:jose, "~> 1.11"}]
    end
  end

  @doc """
  Validates that a configured `:key_provider` module exists and implements
  both `c:ConduitMcp.OAuth.KeyProvider.fetch_keys/1` and
  `c:ConduitMcp.OAuth.KeyProvider.fetch_key/2`.

  `ConduitMcp.Plugs.OAuth`'s `init/1` accepts any atom as a key provider and
  dispatch is unguarded, so without this a missing provider or callback
  surfaces as an `UndefinedFunctionError` on the first authenticated request.
  """
  @spec validate_key_provider!(module()) :: :ok
  def validate_key_provider!(mod) when is_atom(mod) do
    cond do
      not Code.ensure_loaded?(mod) and mod == @jwks_provider ->
        raise OptionalDependencyError,
          feature: "The JWKS key provider",
          module: @jwks_provider,
          deps: @req_deps

      not Code.ensure_loaded?(mod) ->
        raise ArgumentError,
              "OAuth :key_provider #{inspect(mod)} could not be loaded. " <>
                "Check the module name and that it is compiled into your release."

      not function_exported?(mod, :fetch_keys, 1) ->
        raise ArgumentError,
              "OAuth :key_provider #{inspect(mod)} does not export fetch_keys/1. " <>
                "Key providers must implement the ConduitMcp.OAuth.KeyProvider behaviour."

      # `fetch_key/2` is the *common* branch, not an optional extra:
      # `fetch_signing_key/2` dispatches on the token's `kid` header, and every
      # token from a real JWKS-publishing authorization server carries one.
      # Checking only `fetch_keys/1` let a half-implemented provider pass
      # `init/1` cleanly and then raise UndefinedFunctionError on the first
      # authenticated request - exactly the failure this module exists to move
      # to boot time.
      not function_exported?(mod, :fetch_key, 2) ->
        raise ArgumentError,
              "OAuth :key_provider #{inspect(mod)} does not export fetch_key/2. " <>
                "Key providers must implement the ConduitMcp.OAuth.KeyProvider behaviour."

      true ->
        :ok
    end
  end
end
