defmodule ConduitMcp.Client.ToolSet do
  @moduledoc """
  The tools offered to an LLM, keyed by the name the model sees.

  Built by `ConduitMcp.Client.Naming.build/2`. Every exposed name matches
  `^[A-Za-z0-9_-]{1,64}$` (valid for Anthropic, OpenAI and Gemini) and maps
  to exactly one `ConduitMcp.Client.Tool`.

  Reverse lookup is a table lookup (`resolve/2` is a `Map.fetch/2`): an
  exposed name is never split back into a server id and a tool name, so a
  tool name containing `__` cannot be used to reach another server's tool.

  `entries` keeps the build order (servers in the given order, then each
  server's tools in listed order), which keeps the provider tool list stable
  between turns and so helps prompt caching.
  """

  alias ConduitMcp.Client.Tool

  defstruct entries: [], by_name: %{}, by_tool: %{}

  @type exposed_name :: String.t()

  @type t :: %__MODULE__{
          entries: [{exposed_name(), Tool.t()}],
          by_name: %{exposed_name() => Tool.t()},
          by_tool: %{{String.t(), String.t()} => exposed_name()}
        }

  @doc """
  Builds a toolset from ordered `{exposed_name, tool}` pairs.

  Exposed names must be unique; `ConduitMcp.Client.Naming.build/2` guarantees
  that, so call this directly only with names you have already deduplicated.
  Raises `ArgumentError` on a duplicate exposed name.
  """
  @spec new([{exposed_name(), Tool.t()}]) :: t()
  def new(entries) when is_list(entries) do
    Enum.reduce(entries, %__MODULE__{}, fn {name, %Tool{} = tool}, acc ->
      if Map.has_key?(acc.by_name, name) do
        raise ArgumentError, "duplicate exposed tool name #{inspect(name)}"
      end

      %{
        acc
        | entries: [{name, tool} | acc.entries],
          by_name: Map.put(acc.by_name, name, tool),
          by_tool: Map.put(acc.by_tool, {tool.server_id, tool.name}, name)
      }
    end)
    |> Map.update!(:entries, &Enum.reverse/1)
  end

  @doc """
  Looks up the tool behind a model-issued name.

  `:error` means the name is unknown: the caller answers the model with an
  error result and sends nothing to any server.
  """
  @spec resolve(t(), term()) :: {:ok, Tool.t()} | :error
  def resolve(%__MODULE__{by_name: by_name}, exposed_name), do: Map.fetch(by_name, exposed_name)

  @doc "The exposed name of `server_id`'s tool `tool_name`, if it is in the set."
  @spec exposed_name(t(), String.t(), String.t()) :: {:ok, exposed_name()} | :error
  def exposed_name(%__MODULE__{by_tool: by_tool}, server_id, tool_name),
    do: Map.fetch(by_tool, {server_id, tool_name})

  @doc "The `{exposed_name, tool}` pairs, in build order."
  @spec entries(t()) :: [{exposed_name(), Tool.t()}]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "The exposed names, in build order."
  @spec names(t()) :: [exposed_name()]
  def names(%__MODULE__{entries: entries}), do: Enum.map(entries, &elem(&1, 0))

  @doc "The number of tools in the set."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{by_name: by_name}), do: map_size(by_name)
end
