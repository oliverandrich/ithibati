# Credo checks

Ithibati ships three optional checks for consuming applications. Enable them in your existing
`.credo.exs` configuration to catch direct table access, unused WebAuthn settings and calls to
internal functions.

## Enable the checks

Include `config/` in the files Credo reads; the WebAuthn configuration check needs it.
Merge these entries into your configuration:

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      # `config/` is not in Credo's default list, and the wax rule has nothing to read without it.
      files: %{included: ["lib/", "test/", "config/"]},
      checks: %{
        extra: [
          {Ithibati.Credo.NoDirectTableAccess, []},
          {Ithibati.Credo.NoWaxConfiguration, []},
          {Ithibati.Credo.NoInternalCalls, []}
        ]
      }
    }
  ]
}
```

Run compilation before Credo so the check modules are available:

```console
$ mix compile
$ mix credo --strict
```

If Credo reports `Ignoring an undefined check`, that check did not run. Confirm that Credo is
installed in the current environment and Ithibati was compiled with it available.

## What each check reports

| Check | Reports | Use instead |
| --- | --- | --- |
| `Ithibati.Credo.NoDirectTableAccess` | Queries and repo operations naming Ithibati-owned schemas or tables | Public identity functions, or supported account associations |
| `Ithibati.Credo.NoWaxConfiguration` | `wax_` settings for `origin` and `rp_id` | Per-call arguments or the web handler's relying-party callback |
| `Ithibati.Credo.NoInternalCalls` | Calls to undocumented Ithibati functions | Documented APIs |

Use `mix credo explain` for a finding's explanation. The check modules' documentation describes
the individual rules.

## Limits

These are static checks, not runtime access controls. Enablement is optional and a clean run
only describes the code the checks can inspect.

`NoDirectTableAccess` recognizes schema references in queries and repo calls, including joins,
and table-name strings using your configured prefix. It does not inspect raw SQL inside a
string. Account associations are allowed; for example, an application may revoke an account's
sessions with `Repo.delete_all(Ecto.assoc(account, :sessions))`.

`NoInternalCalls` permits generated reflection functions such as `__schema__/1` and
`__struct__/0`. It cannot classify a module whose documentation chunk was stripped, and it
skips ambiguous aliases when the same short name means different modules within a file.

Use [`mix ithibati.doctor`](doctor.md) alongside these checks to inspect actual configuration,
tables, indexes and handler wiring.
