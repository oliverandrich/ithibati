# Only what this project adds. `checks: %{extra: …}` keeps Credo's own default set rather than
# freezing a copy of it here, so an upgrade that adds a check is not silently ignored — which is
# what `mix credo.gen.config` would produce.
%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      files: %{included: ["lib/", "test/", "adapter_test/", "credo/", "mix.exs"]},
      checks: %{
        extra: [
          {Ithibati.Credo.IdentityIsPortable, []},
          {Ithibati.Credo.NoBeanIds, []},
          # Exact list sizes are useful assertions, including for generated recovery codes.
          {ExSlop.Check.Refactor.LengthComparison, files: %{excluded: ["test/"]}}
        ]
      }
    }
  ]
}
