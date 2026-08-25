defmodule ConduitMcp.ServerMeta do
  @moduledoc false

  # Lazily caches `function_exported?/3` results for a server module in
  # persistent_term, eliminating repeated BIF calls on every request.
  # The result never changes at runtime for compiled server modules.

  @doc """
  Returns true if the server module exports the given capability.
  """
  def has?(server_module, capability) do
    meta = get_or_compute(server_module)
    Map.get(meta, capability, false)
  end

  @doc """
  Clears the cached metadata for a server module.

  Useful in tests when redefining modules dynamically.
  """
  def clear(server_module) do
    :persistent_term.erase({__MODULE__, server_module})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp get_or_compute(server_module) do
    key = {__MODULE__, server_module}

    case :persistent_term.get(key, nil) do
      nil ->
        meta = compute(server_module)
        :persistent_term.put(key, meta)
        meta

      meta ->
        meta
    end
  end

  defp compute(server_module) do
    %{
      scope_for_tool: function_exported?(server_module, :__scope_for_tool__, 1),
      scope_for_prompt: function_exported?(server_module, :__scope_for_prompt__, 1),
      scope_for_resource: function_exported?(server_module, :__scope_for_resource__, 1),
      validation_schema_tool:
        function_exported?(server_module, :__validation_schema_for_tool__, 1),
      validation_schema_prompt:
        function_exported?(server_module, :__validation_schema_for_prompt__, 1),
      capabilities: function_exported?(server_module, :__capabilities__, 0),
      complete: function_exported?(server_module, :handle_complete, 3),
      set_log_level: function_exported?(server_module, :handle_set_log_level, 2),
      subscribe: function_exported?(server_module, :handle_subscribe_resource, 2),
      unsubscribe: function_exported?(server_module, :handle_unsubscribe_resource, 2),
      list_resource_templates:
        function_exported?(server_module, :handle_list_resource_templates, 1),
      list_tools_2: function_exported?(server_module, :handle_list_tools, 2),
      list_resources_2: function_exported?(server_module, :handle_list_resources, 2),
      list_prompts_2: function_exported?(server_module, :handle_list_prompts, 2)
    }
  end
end
