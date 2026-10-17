defmodule ConduitMcp.Client.Prompt do
  @moduledoc """
  A prompt listed by a server (`prompts/list`).

  `arguments` is the list of wire `PromptArgument` maps (string keys:
  `"name"`, `"title"`, `"description"`, `"required"`), keeping only entries
  that are maps with a string `"name"`. `raw` keeps the wire map untouched.
  Prompt argument values sent to `prompts/get` are always strings.
  """

  alias ConduitMcp.Client.Wire

  @enforce_keys [:server_id, :name, :raw]
  defstruct [:server_id, :name, :title, :description, :raw, arguments: [], meta: %{}]

  @type t :: %__MODULE__{
          server_id: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          arguments: [map()],
          meta: map(),
          raw: map()
        }

  @doc """
  Builds a `Prompt` from a wire `Prompt` map listed by `server_id`.

  `name` must be a string; otherwise the result is a `:protocol` error with
  reason `:invalid_prompt`.

      iex> {:ok, prompt} =
      ...>   ConduitMcp.Client.Prompt.from_wire("docs", %{
      ...>     "name" => "summarize",
      ...>     "arguments" => [%{"name" => "topic", "required" => true}]
      ...>   })
      iex> Enum.map(prompt.arguments, & &1["name"])
      ["topic"]
  """
  @spec from_wire(String.t(), term()) :: {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(server_id, %{"name" => name} = raw)
      when is_binary(server_id) and is_binary(name) do
    {:ok,
     %__MODULE__{
       server_id: server_id,
       name: name,
       title: Wire.string(raw, "title"),
       description: Wire.string(raw, "description"),
       arguments: arguments(raw),
       meta: Wire.meta(raw),
       raw: raw
     }}
  end

  def from_wire(_server_id, other), do: Wire.invalid(:invalid_prompt, other)

  defp arguments(raw) do
    raw
    |> Wire.list("arguments")
    |> List.wrap()
    |> Enum.filter(&match?(%{"name" => name} when is_binary(name), &1))
  end
end
