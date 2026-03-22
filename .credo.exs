%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Raise max complexity for router/validator functions
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 20},
          # Raise max nesting for case/with chains
          {Credo.Check.Refactor.Nesting, max_nesting: 4},
          # length/1 is fine in test assertions — small lists, clarity matters more
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          # TODO tags are acceptable in tests
          {Credo.Check.Design.TagTODO, exit_status: 0}
        ]
      }
    }
  ]
}
