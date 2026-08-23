# Credo configuration. This project is a faithful port of grok-mermaid's
# TypeScript: the layout/parse loops intentionally keep the reference
# structure, so nesting and complexity thresholds are relaxed compared to
# the strict defaults while every other check stays on.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/reference/"]
      },
      plugins: [{ExSlop, []}],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          # Ported loops keep the reference structure.
          {Credo.Check.Refactor.Nesting, false},
          # is_alphanumeric/is_id_char mirror Rust's is_* naming.
          {Credo.Check.Readability.PredicateFunctionNames, false},
          {Credo.Check.Refactor.CyclomaticComplexity, false}
        ],
        enabled: [
          {Credo.Check.Refactor.FunctionArity, max_arity: 12}
        ] ++ Enum.map(ExSlop.recommended_checks(), &{&1, []})
      }
    }
  ]
}
