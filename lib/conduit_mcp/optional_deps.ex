defmodule ConduitMcp.OptionalDeps do
  @moduledoc """
  Runtime availability checks for ConduitMCP's conditionally compiled modules.

  `ConduitMcp.Plugs.OAuth` and `ConduitMcp.OAuth.KeyProvider.JWKS` only exist
  when their optional dependency was present when `:conduit_mcp` was compiled.
  Every code path that can reach one of them crosses a plug's `init/1`, so
  availability is validated there — once, at boot or compile time — rather
  than degrading into a per-request failure that is indistinguishable from a
  configuration mistake.

  See `ConduitMcp.OptionalDependencyError` for why adding the dependency to
  `mix.exs` is not sufficient on its own.
  """

  alias ConduitMcp.OptionalDependencyError

  @oauth_plug ConduitMcp.Plugs.OAuth
  @jwks_provider ConduitMcp.OAuth.KeyProvider.JWKS

  @joken_deps [{:joken, "~> 2.6"}, {:jose, "~> 1.11"}]
  @req_deps [{:req, "~> 0.6.1 or ~> 0.7"}]

  @doc """
  Returns the OAuth plug module, raising `ConduitMcp.OptionalDependencyError`
  when it was not compiled in.
  """
  @spec oauth_plug!() :: module()
  def oauth_plug! do
    if Code.ensure_loaded?(@oauth_plug) do
      @oauth_plug
    else
      raise OptionalDependencyError,
        feature: "The :oauth auth strategy",
        module: @oauth_plug,
        deps: @joken_deps
    end
  end

  @doc """
  Returns `true` when the `:oauth` auth strategy is usable in this build.
  """
  @spec oauth_available?() :: boolean()
  def oauth_available?, do: Code.ensure_loaded?(@oauth_plug)

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
