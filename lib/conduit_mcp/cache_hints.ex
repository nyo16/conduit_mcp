defmodule ConduitMcp.CacheHints do
  @moduledoc """
  Per-component cache hints for modern (`2026-07-28`) results.

  Complete results of `tools/list`, `prompts/list`, `resources/list`,
  `resources/templates/list`, `resources/read` and `server/discover` carry
  `ttlMs` and `cacheScope`
  ([caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)).
  The defaults come from the application environment, validated when
  `:conduit_mcp` starts:

      config :conduit_mcp, cache_ttl_ms: 60_000, cache_scope: :private

  (`cache_ttl_ms` a non-negative integer, `cache_scope` `:private` or
  `:public`.) A tool, prompt or resource can override them:

      # DSL, inside a tool/prompt/resource block
      tool "catalog", "Public catalog" do
        cache ttl_ms: 5_000, scope: :public
        handle fn _conn, _params -> text("...") end
      end

      # ConduitMcp.Component option
      use ConduitMcp.Component, type: :tool, description: "...",
        cache: [ttl_ms: 5_000, scope: :public]

  Either key may be omitted; it then falls back to the global default.
  `ConduitMcp.Endpoint` collects its components' `:cache` options.

  ## Resolution

    * A list result: the **minimum** TTL across the listed items, and
      `private` if **any** listed item is private — or is gated by a
      `scope` (SV-9: a scoped item must never be cached as public, even
      when the global default is `:public`). An empty list uses the
      defaults.
    * `resources/read`: the hint of the resource that serves the URI (its
      exact static URI, else the first matching template), `private` when
      it is scoped.
    * `server/discover`: the defaults.

  Declaring both `scope` and `cache scope: :public` on one item is a
  compile error.

  ## Manual servers

  A `use ConduitMcp.Server, dsl: false` module gets the defaults (with the
  SV-9 rule applied through its `__scope_for_*__/1` lookups, if any). It may
  define `__cache_hints__/0` returning a `t:hints/0` to declare overrides.
  """

  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Protocol.Modern
  alias ConduitMcp.ServerMeta

  @typedoc "A declared override; `nil` keys fall back to the defaults."
  @type hint :: %{ttl_ms: non_neg_integer() | nil, scope: :private | :public | nil}

  @typedoc """
  The hints a server declares (`__cache_hints__/0`): tools and prompts by
  name, resources as `{uri_or_template, hint}` in dispatch order.
  """
  @type hints :: %{
          tools: %{optional(String.t()) => hint()},
          prompts: %{optional(String.t()) => hint()},
          resources: [{String.t(), hint()}]
        }

  @empty %{tools: %{}, prompts: %{}, resources: []}

  @doc false
  # Compile-time validation shared by the DSL, Component and Endpoint.
  # Returns the normalized hint, or `nil` when nothing was declared.
  @spec validate!(term(), term(), String.t() | nil) :: hint() | nil
  def validate!(nil, _subject, _scope), do: nil

  def validate!(opts, subject, scope) when is_list(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:ttl_ms, :scope] == [] do
      invalid!(subject, opts)
    end

    ttl_ms = Keyword.get(opts, :ttl_ms)
    cache_scope = Keyword.get(opts, :scope)

    unless is_nil(ttl_ms) or (is_integer(ttl_ms) and ttl_ms >= 0), do: invalid!(subject, opts)
    unless cache_scope in [nil, :private, :public], do: invalid!(subject, opts)

    if cache_scope == :public and not is_nil(scope) do
      raise CompileError,
        description:
          "#{inspect(subject)}: cache scope: :public cannot be combined with scope " <>
            "#{inspect(scope)}; a scoped response is per-principal and must stay private (SV-9)"
    end

    %{ttl_ms: ttl_ms, scope: cache_scope}
  end

  def validate!(opts, subject, _scope), do: invalid!(subject, opts)

  defp invalid!(subject, opts) do
    raise CompileError,
      description:
        "#{inspect(subject)}: cache expects [ttl_ms: non_neg_integer, scope: :private | :public]; " <>
          "got #{inspect(opts)}"
  end

  @doc """
  Validates the global `:cache_ttl_ms` / `:cache_scope` application env;
  raises `ArgumentError` naming the key.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    case Application.fetch_env(:conduit_mcp, :cache_ttl_ms) do
      {:ok, ttl} when is_integer(ttl) and ttl >= 0 -> :ok
      :error -> :ok
      {:ok, other} -> config_error!(:cache_ttl_ms, "a non-negative integer", other)
    end

    case Application.fetch_env(:conduit_mcp, :cache_scope) do
      {:ok, scope} when scope in [:private, :public] -> :ok
      :error -> :ok
      {:ok, other} -> config_error!(:cache_scope, ":private or :public", other)
    end
  end

  defp config_error!(key, expected, got) do
    raise ArgumentError,
          "config :conduit_mcp, #{inspect(key)} must be #{expected}; got #{inspect(got)}"
  end

  @doc """
  The hints `server_module` declares (empty when it defines no
  `__cache_hints__/0`).
  """
  @spec hints(module()) :: hints()
  def hints(server_module) do
    if ServerMeta.has?(server_module, :cache_hints),
      do: server_module.__cache_hints__(),
      else: @empty
  end

  @doc """
  The cache hints for `method`'s complete `result` from `server_module`
  (see "Resolution"), or `nil` for a method without them.
  """
  @spec resolve(module(), String.t() | nil, map(), map()) :: Modern.cache() | nil
  def resolve(server_module, method, params, result) do
    if method in Modern.cacheable_methods() do
      merge(items(server_module, method, params, result), Modern.default_cache())
    end
  end

  defp items(server_module, "tools/list", _params, result) do
    hints = hints(server_module).tools

    for name <- keys(result, "tools", "name"),
        do: {Map.get(hints, name), Common.required_scope(server_module, :scope_for_tool, name)}
  end

  defp items(server_module, "prompts/list", _params, result) do
    hints = hints(server_module).prompts

    for name <- keys(result, "prompts", "name"),
        do: {Map.get(hints, name), Common.required_scope(server_module, :scope_for_prompt, name)}
  end

  defp items(server_module, "resources/list", _params, result) do
    for uri <- keys(result, "resources", "uri"), do: resource_item(server_module, uri)
  end

  defp items(server_module, "resources/templates/list", _params, result) do
    hints = hints(server_module).resources

    for template <- keys(result, "resourceTemplates", "uriTemplate") do
      hint = Enum.find_value(hints, fn {key, hint} -> if key == template, do: {:hint, hint} end)

      {unwrap(hint), Common.required_scope(server_module, :scope_for_resource, template)}
    end
  end

  defp items(server_module, "resources/read", %{"uri" => uri}, _result) when is_binary(uri),
    do: [resource_item(server_module, uri)]

  defp items(_server_module, _method, _params, _result), do: []

  # Mirrors dispatch: an exact static URI first, then the first matching
  # template.
  defp resource_item(server_module, uri) do
    hints = hints(server_module).resources

    hint =
      Enum.find_value(hints, fn {key, hint} -> if key == uri, do: {:hint, hint} end) ||
        Enum.find_value(hints, fn {template, hint} ->
          if String.contains?(template, "{") and matches?(server_module, template, uri),
            do: {:hint, hint}
        end)

    {unwrap(hint), Common.required_scope(server_module, :scope_for_resource, uri)}
  end

  defp matches?(server_module, template, uri) do
    {param_names, regex} = ConduitMcp.DSL.template_regex(server_module, template)
    match?({:ok, _}, ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex))
  end

  defp unwrap({:hint, hint}), do: hint
  defp unwrap(nil), do: nil

  defp keys(result, list_key, item_key) do
    case Map.get(result, list_key) do
      items when is_list(items) ->
        for %{^item_key => key} <- items, is_binary(key), do: key

      _ ->
        []
    end
  end

  defp merge([], default), do: default

  defp merge(items, default) do
    effective =
      Enum.map(items, fn {hint, required_scope} ->
        hint = hint || %{}
        ttl = Map.get(hint, :ttl_ms) || default.ttl_ms
        scope = if required_scope, do: :private, else: Map.get(hint, :scope) || default.scope
        {ttl, scope}
      end)

    %{
      ttl_ms: effective |> Enum.map(&elem(&1, 0)) |> Enum.min(),
      scope: if(Enum.any?(effective, &(elem(&1, 1) == :private)), do: :private, else: :public)
    }
  end
end
