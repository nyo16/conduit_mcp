defmodule ConduitMcp.Client.Tool do
  @moduledoc """
  A tool advertised by one server, as the client holds it.

  `raw` is the server's string-keyed tool definition, untouched: it is what
  fingerprints are computed over and what LLM adapters read, and it keeps
  keys this struct does not lift (`icons`, future fields). The other fields
  are read-only conveniences lifted from `raw`:

    * `name`, `title`, `description`
    * `input_schema` (`inputSchema`), `output_schema` (`outputSchema`)
    * `annotations` - hints only. They are untrusted unless the server is
      configured as trusted, and never drive policy on their own.
    * `execution` - legacy task support (`execution.taskSupport`)
    * `meta` - the tool's `_meta`, or `%{}`

  `server_id` is the operator-assigned id of the server that listed the tool
  (never the self-reported `serverInfo.name`). `fingerprint` is the digest the
  client pins approvals to; it is `nil` until the caller sets it.
  """

  alias ConduitMcp.Client.Wire

  @enforce_keys [:server_id, :name, :input_schema, :raw]
  defstruct [
    :server_id,
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :execution,
    :fingerprint,
    :raw,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          server_id: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          annotations: map() | nil,
          execution: map() | nil,
          meta: map(),
          fingerprint: String.t() | nil,
          raw: map()
        }

  @doc """
  Builds a `Tool` from a wire `Tool` definition listed by `server_id`.

  `name` must be a string and `inputSchema` an object; anything else is a
  `:protocol` error with reason `:invalid_tool`. This checks shape only: the
  name charset and `x-mcp-header` rules are enforced at tool intake.

  ## Options

    * `:fingerprint` - the value for the `fingerprint` field (default `nil`).

  ## Example

      iex> {:ok, tool} =
      ...>   ConduitMcp.Client.Tool.from_wire("files", %{
      ...>     "name" => "read",
      ...>     "inputSchema" => %{"type" => "object"}
      ...>   })
      iex> {tool.server_id, tool.name}
      {"files", "read"}
  """
  @spec from_wire(String.t(), term(), keyword()) ::
          {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(server_id, definition, opts \\ [])

  def from_wire(server_id, %{"name" => name, "inputSchema" => schema} = raw, opts)
      when is_binary(server_id) and is_binary(name) and is_map(schema) do
    {:ok,
     %__MODULE__{
       server_id: server_id,
       name: name,
       title: Wire.string(raw, "title"),
       description: Wire.string(raw, "description"),
       input_schema: schema,
       output_schema: Wire.object(raw, "outputSchema"),
       annotations: Wire.object(raw, "annotations"),
       execution: Wire.object(raw, "execution"),
       meta: Wire.meta(raw),
       fingerprint: Keyword.get(opts, :fingerprint),
       raw: raw
     }}
  end

  def from_wire(_server_id, definition, _opts), do: Wire.invalid(:invalid_tool, definition)

  @doc """
  The display name, by the spec's precedence: `title`, then
  `annotations.title`, then `name`.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{title: title}) when is_binary(title), do: title

  def display_name(%__MODULE__{annotations: %{"title" => title}}) when is_binary(title),
    do: title

  def display_name(%__MODULE__{name: name}), do: name
end
