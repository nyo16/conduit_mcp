defmodule Examples.ObanTasks.Schema.McpTask do
  @moduledoc """
  Ecto schema for the `mcp_tasks` table. Columns mirror the map shape
  that `ConduitMcp.Tasks` uses elsewhere — `"task_id"`, `"status"`,
  `"created_at"` (ms epoch) — so the to-map conversion is a near-identity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:task_id, :string, autogenerate: false}
  schema "mcp_tasks" do
    field(:status, :string, default: "working")
    field(:oban_job_id, :integer)
    field(:tool, :string)
    field(:args, :map)
    field(:result, :map)
    field(:metadata, :map)
    field(:created_at, :integer)

    timestamps()
  end

  @cast_fields ~w(task_id status oban_job_id tool args result metadata created_at)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @cast_fields)
    |> validate_required([:task_id, :status, :created_at])
  end

  @doc """
  Converts a schema row into the string-keyed map shape that the rest
  of ConduitMCP works with. nil fields are dropped so the wire payload
  stays compact.
  """
  def to_map(%__MODULE__{} = row) do
    %{
      "task_id" => row.task_id,
      "status" => row.status,
      "created_at" => row.created_at
    }
    |> maybe_put("oban_job_id", row.oban_job_id)
    |> maybe_put("tool", row.tool)
    |> maybe_put("args", row.args)
    |> maybe_put("result", row.result)
    |> maybe_put("metadata", row.metadata)
    |> promote_owner(row.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Owner scoping: a task stamped via `ConduitMcp.Tasks.create/3` carries its
  # owner in the metadata blob; surface it at the top-level "owner" key so the
  # framework's owner-scoping (get/2, cancel/2, list/2) can enforce it. This
  # example server runs unauthenticated, so the owner is always nil here and
  # this is a no-op — see the "Owner scoping" section of `ConduitMcp.Tasks.Store`.
  defp promote_owner(map, %{"owner" => owner}) when not is_nil(owner),
    do: Map.put(map, "owner", owner)

  defp promote_owner(map, _metadata), do: map
end
