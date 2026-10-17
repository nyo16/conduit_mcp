defmodule ConduitMcp.OptionalDependencyError do
  @moduledoc """
  Raised when a feature is configured whose optional dependency is not
  compiled into the current build of `:conduit_mcp`.

  Several ConduitMCP modules are wrapped in `if Code.ensure_loaded?(Dep)`
  guards, which is *conditional compilation*: whether the module exists is
  decided once, when `:conduit_mcp` itself is compiled inside the consuming
  project's `_build`. Mix does not recompile an already-built dependency when
  the consumer later adds one of its optional deps, so adding `:joken` to
  `mix.exs` is not by itself enough — `mix deps.compile conduit_mcp --force`
  is required.

  The message therefore always names both the missing dependency and the
  rebuild command.
  """

  defexception [:feature, :module, :deps, :message]

  @type t :: %__MODULE__{
          feature: String.t(),
          module: module(),
          deps: [{atom(), String.t()}],
          message: String.t()
        }

  @impl true
  def exception(opts) do
    feature = Keyword.fetch!(opts, :feature)
    module = Keyword.fetch!(opts, :module)
    deps = Keyword.fetch!(opts, :deps)

    %__MODULE__{
      feature: feature,
      module: module,
      deps: deps,
      message: build_message(feature, module, deps)
    }
  end

  defp build_message(feature, module, deps) do
    """
    #{feature} requires #{inspect(module)}, which is not compiled into this \
    build of :conduit_mcp.

    #{inspect(module)} is compiled only when #{dep_names(deps)} #{verb(deps)} available.
    Add to your mix.exs deps:

    #{mix_lines(deps)}

    Then force a rebuild of :conduit_mcp. Mix does not recompile an
    already-built dependency when you later add one of its optional deps:

        mix deps.get
        mix deps.compile conduit_mcp --force
    """
  end

  defp dep_names(deps), do: Enum.map_join(deps, " and ", fn {name, _req} -> inspect(name) end)

  defp verb([_single]), do: "is"
  defp verb(_deps), do: "are"

  defp mix_lines(deps) do
    Enum.map_join(deps, "\n", fn {name, req} -> "        {#{inspect(name)}, #{inspect(req)}}," end)
  end
end
