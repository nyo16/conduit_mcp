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
        # `extra:` adjusts the default check suite; `enabled:` would REPLACE it
        # (running only the listed checks).
        extra: [
          # Raise max complexity for router/validator functions
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 20},
          # Raise max nesting for case/with chains
          {Credo.Check.Refactor.Nesting, max_nesting: 4},
          # length/1 is fine in test assertions — small lists, clarity matters more
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          # TODO tags are acceptable in tests
          {Credo.Check.Design.TagTODO, exit_status: 0},
          # Fully-qualified module calls are intentional house style in this library
          {Credo.Check.Design.AliasUsage, false},
          # JSON-RPC error codes (-32601 etc.) stay spec-literal for greppability;
          # still flag genuinely large numbers
          {Credo.Check.Readability.LargeNumbers, only_greater_than: 99_999},
          # Library emits Logger metadata for host apps to expose in their own
          # Logger config; there is no config dir here to declare keys
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false}
        ]
      }
    }
  ]
}
