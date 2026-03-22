Code.require_file("bench/bench_helper.exs")

alias Bench.Fixtures
alias Bench.Alternatives

IO.puts("\n=== Validation Pipeline Benchmark ===")
IO.puts("Measures: key conversion, constraint validation, marker removal, config lookups\n")

# Ensure atoms exist for to_existing_atom tests
_ = [:message, :name, :email, :age, :role, :active]
for i <- 1..20, do: :"field_#{i}"

small = Fixtures.small_params()
medium = Fixtures.medium_params()
large = Fixtures.large_params()

# Pre-build key maps for the key-map alternative
small_key_map = %{"message" => :message}

medium_key_map = %{
  "name" => :name,
  "email" => :email,
  "age" => :age,
  "role" => :role,
  "active" => :active
}

large_key_map = Enum.into(1..20, %{}, fn i -> {"field_#{i}", :"field_#{i}"} end)

# Get validation schemas for constraint benchmarks
medium_schema =
  if function_exported?(Bench.DSLServer, :__validation_schema_for_tool__, 1) do
    Bench.DSLServer.__validation_schema_for_tool__("create_user") || []
  else
    []
  end

large_schema =
  if function_exported?(Bench.DSLServer, :__validation_schema_for_tool__, 1) do
    Bench.DSLServer.__validation_schema_for_tool__("bulk_import") || []
  else
    []
  end

# --- Section 1: Full validation pipeline ---

IO.puts("--- Full Validation Pipeline ---\n")

Benchee.run(
  %{
    "full: 1 param (echo)" => fn ->
      ConduitMcp.Validation.validate_tool_params(Bench.DSLServer, "echo", small)
    end,
    "full: 5 params (create_user)" => fn ->
      ConduitMcp.Validation.validate_tool_params(Bench.DSLServer, "create_user", medium)
    end,
    "full: 20 params (bulk_import)" => fn ->
      ConduitMcp.Validation.validate_tool_params(Bench.DSLServer, "bulk_import", large)
    end,
    "full: validation disabled (passthrough)" => fn ->
      Application.put_env(:conduit_mcp, :validation, runtime_validation: false)
      result = ConduitMcp.Validation.validate_tool_params(Bench.DSLServer, "echo", small)

      Application.put_env(:conduit_mcp, :validation,
        runtime_validation: true,
        type_coercion: true,
        log_validation_errors: false
      )

      result
    end,
    "full: manual server (no schemas, passthrough)" => fn ->
      ConduitMcp.Validation.validate_tool_params(Bench.ManualServer, "echo", small)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/validation_full.html"}
  ]
)

# --- Section 2: Key conversion ---

IO.puts("\n--- Key Conversion ---\n")

Benchee.run(
  %{
    "String.to_atom: 1 key" => fn -> Alternatives.convert_keys_to_atoms(small) end,
    "String.to_atom: 5 keys" => fn -> Alternatives.convert_keys_to_atoms(medium) end,
    "String.to_atom: 20 keys" => fn -> Alternatives.convert_keys_to_atoms(large) end,
    "String.to_existing_atom: 1 key" => fn ->
      Alternatives.convert_keys_to_existing_atoms(small)
    end,
    "String.to_existing_atom: 5 keys" => fn ->
      Alternatives.convert_keys_to_existing_atoms(medium)
    end,
    "String.to_existing_atom: 20 keys" => fn ->
      Alternatives.convert_keys_to_existing_atoms(large)
    end,
    "key map lookup: 1 key" => fn -> Alternatives.convert_with_key_map(small, small_key_map) end,
    "key map lookup: 5 keys" => fn ->
      Alternatives.convert_with_key_map(medium, medium_key_map)
    end,
    "key map lookup: 20 keys" => fn -> Alternatives.convert_with_key_map(large, large_key_map) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/validation_keys.html"}
  ]
)

# --- Section 3: Constraint validation (4-pass vs single-pass) ---

if medium_schema != [] do
  IO.puts("\n--- Constraint Validation: 4-pass vs Single-pass ---\n")

  # Prepare atom-keyed params for constraint validation
  medium_atom = Alternatives.convert_keys_to_atoms(medium)

  Benchee.run(
    %{
      "4-pass: 5 params" => fn ->
        Alternatives.validate_four_passes(medium_atom, medium_schema)
      end,
      "single-pass: 5 params" => fn ->
        Alternatives.validate_single_pass(medium_atom, medium_schema)
      end
    },
    warmup: 2,
    time: 5,
    memory_time: 2,
    formatters: [
      Benchee.Formatters.Console,
      {Benchee.Formatters.HTML, file: "bench/output/validation_constraints.html"}
    ]
  )
end

# --- Section 4: Marker removal ---

if medium_schema != [] do
  IO.puts("\n--- Marker Removal: Enum.reduce vs Keyword.drop ---\n")

  Benchee.run(
    %{
      "Enum.reduce: 5-param schema" => fn -> Alternatives.remove_markers_reduce(medium_schema) end,
      "Keyword.drop: 5-param schema" => fn -> Alternatives.remove_markers_drop(medium_schema) end
    },
    warmup: 2,
    time: 3,
    memory_time: 2,
    formatters: [
      Benchee.Formatters.Console,
      {Benchee.Formatters.HTML, file: "bench/output/validation_markers.html"}
    ]
  )
end

# --- Section 5: Application.get_env overhead ---

IO.puts("\n--- Application.get_env overhead ---\n")

# Store config in persistent_term for comparison
:persistent_term.put(:bench_validation_config, Application.get_env(:conduit_mcp, :validation, []))

Benchee.run(
  %{
    "Application.get_env x3 (current)" => fn ->
      config1 =
        Application.get_env(:conduit_mcp, :validation, [])
        |> Keyword.get(:runtime_validation, true)

      config2 =
        Application.get_env(:conduit_mcp, :validation, []) |> Keyword.get(:type_coercion, true)

      config3 =
        Application.get_env(:conduit_mcp, :validation, [])
        |> Keyword.get(:log_validation_errors, false)

      {config1, config2, config3}
    end,
    "Application.get_env x1 (fetch once)" => fn ->
      config = Application.get_env(:conduit_mcp, :validation, [])
      config1 = Keyword.get(config, :runtime_validation, true)
      config2 = Keyword.get(config, :type_coercion, true)
      config3 = Keyword.get(config, :log_validation_errors, false)
      {config1, config2, config3}
    end,
    "persistent_term.get (cached)" => fn ->
      config = :persistent_term.get(:bench_validation_config)
      config1 = Keyword.get(config, :runtime_validation, true)
      config2 = Keyword.get(config, :type_coercion, true)
      config3 = Keyword.get(config, :log_validation_errors, false)
      {config1, config2, config3}
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/validation_config.html"}
  ]
)

# Cleanup
:persistent_term.erase(:bench_validation_config)
