Code.require_file("bench/bench_helper.exs")

# Pre-compile regex for comparison
simple_precompiled = Bench.Alternatives.precompile_uri_template("user://{id}")
complex_precompiled = Bench.Alternatives.precompile_uri_template("project://{org}/{repo}")

IO.puts("\n=== URI Template Matching Benchmark ===")
IO.puts("Measures: extract_uri_params/2 — dynamic regex vs pre-compiled vs String.split\n")

Benchee.run(
  %{
    # --- Current implementation ---
    "current: 1 param (user://{id})" => fn ->
      ConduitMcp.DSL.extract_uri_params("user://{id}", "user://123")
    end,
    "current: 2 params (project://{org}/{repo})" => fn ->
      ConduitMcp.DSL.extract_uri_params("project://{org}/{repo}", "project://acme/widgets")
    end,
    "current: no match" => fn ->
      ConduitMcp.DSL.extract_uri_params("user://{id}", "project://123")
    end,

    # --- Pre-compiled regex ---
    "precompiled: 1 param" => fn ->
      Bench.Alternatives.extract_with_precompiled("user://123", simple_precompiled)
    end,
    "precompiled: 2 params" => fn ->
      Bench.Alternatives.extract_with_precompiled("project://acme/widgets", complex_precompiled)
    end,

    # --- String.split approach ---
    "split: 1 param" => fn ->
      Bench.Alternatives.extract_with_split("user://{id}", "user://123")
    end,
    "split: 2 params" => fn ->
      Bench.Alternatives.extract_with_split("project://{org}/{repo}", "project://acme/widgets")
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/uri_template.html"}
  ]
)
