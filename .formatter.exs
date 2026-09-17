# Used by "mix format"
# `import_deps` is what teaches the formatter that `create`, `add` and `field` take no parentheses.
[
  # Exported so that a consuming project's formatter leaves `ithibati_routes handler: …` alone.
  # Without it the formatter rewrites the call the README shows into the parenthesised form, and a
  # consumer running `mix format --check-formatted` in CI goes red on this library's own documented
  # call style. Reached by adding `:ithibati` to their `import_deps`.
  export: [locals_without_parens: [ithibati_routes: 1]],
  import_deps: [:ecto, :ecto_sql],
  locals_without_parens: [ithibati_routes: 1],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,adapter_test}/**/*.{ex,exs}"]
]
