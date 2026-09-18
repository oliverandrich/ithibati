# Only what this project adds. `checks: %{extra: …}` keeps Credo's own default set rather than
# freezing a copy of it here, so an upgrade that adds a check is not silently ignored — which is
# what `mix credo.gen.config` would produce.
%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      files: %{
        included: [
          "lib/",
          "test/",
          "adapter_test/",
          "credo/",
          "mix.exs",
          "examples/email_registration/lib/",
          "examples/email_registration/test/",
          "examples/*/priv/repo/migrations/"
        ]
      },
      checks: %{
        extra: [
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.UndeclaredExternalResource, []},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          {Jump.CredoChecks.NoManualContentDisposition, []},
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},
          {Jump.CredoChecks.LiveViewFormCanBeRehydrated, []},
          {Jump.CredoChecks.LiveViewPubSubRequiresConnected, []},
          # Test/adapter migrations are disposable fixtures; deployment safety applies
          # to the example applications. The library's migration API has behavior tests.
          {ExcellentMigrations.CredoCheck.MigrationsSafety,
           files: %{included: ["examples/*/priv/repo/migrations/"]}},
          {Ithibati.Credo.IdentityIsPortable, []},
          {Ithibati.Credo.NoBeanIds, []},
          # Exact list sizes are useful assertions, including for generated recovery codes.
          {ExSlop.Check.Refactor.LengthComparison, files: %{excluded: ["test/"]}}
        ]
      }
    }
  ]
}
