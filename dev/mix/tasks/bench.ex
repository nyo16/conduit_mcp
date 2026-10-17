defmodule Mix.Tasks.Bench do
  @moduledoc """
  Runs ConduitMCP benchmarks.

  ## Usage

      mix bench                    # Run all benchmarks
      mix bench uri_template       # Run a specific benchmark
      mix bench --list             # List available benchmarks
  """

  @shortdoc "Run ConduitMCP benchmarks"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    File.mkdir_p!("bench/output")

    bench_files =
      Path.wildcard("bench/*_bench.exs")
      |> Enum.sort()

    case args do
      ["--list"] ->
        IO.puts("Available benchmarks:\n")

        Enum.each(bench_files, fn file ->
          name = Path.basename(file, "_bench.exs")
          IO.puts("  #{name}")
        end)

      [name] ->
        files = Enum.filter(bench_files, &String.contains?(&1, name))

        if files == [] do
          Mix.shell().error(
            "No benchmark matching '#{name}'. Run `mix bench --list` to see available."
          )
        else
          run_files(files)
        end

      [] ->
        run_files(bench_files)

      _ ->
        Mix.shell().error("Usage: mix bench [name | --list]")
    end
  end

  defp run_files(files) do
    Enum.each(files, fn file ->
      IO.puts("\n#{IO.ANSI.bright()}=== Running #{Path.basename(file)} ===#{IO.ANSI.reset()}\n")
      Code.eval_file(file)
    end)

    IO.puts("\n#{IO.ANSI.bright()}HTML reports saved to bench/output/#{IO.ANSI.reset()}")
  end
end
