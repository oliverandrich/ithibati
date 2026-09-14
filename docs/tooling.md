# Tooling

## `mix ithibati.doctor`

Asks everything this library needs an application to have got right, and answers about each.
`Ithibati.Doctor` says why it exists; this page is about running it.

```console
$ mix ithibati.doctor
ok   config :ithibati, user_schema:
    MyApp.Accounts.User
bad  this library's tables
    ithibati_keys, ithibati_recovery_codes, ithibati_tokens, ithibati_bootstrap are missing — run
    this library's migration, or check `config :ithibati, table_prefix:` against what it created.
skip config :ithibati, users_key_type:
    the repo did not answer
...
** (Mix) 2 things to fix.
```

Ten questions in all; a healthy run ends with `Nothing to fix.` and exits zero. So it can sit in
your own gate:

```elixir
# mix.exs
defp aliases do
  [precommit: ["compile --warning-as-errors", "ithibati.doctor", "test"]]
end
```

### The questions only this can ask

Most of what it asks is configuration, and it asks by calling the same code that refuses at run
time. Four questions have nowhere else to live:

- **The repo answers.** Being configured means the module exists and is an Ecto repo. It does not
  mean it is in your supervision tree or that its database is up.
- **This library's tables exist, under the prefix you configured.** An application that configured
  everything and never wrote the migration passes every other check and fails at the first
  ceremony. If you set `config :ithibati, table_prefix:` *after* migrating, this is where you find
  out. It asks under the prefix your repo migrates into by default and says which one that was, so
  an application migrating into a prefix chosen per run — `mix ecto.migrate --prefix tenant1` — is
  told about tables the doctor was not looking at.
- **`users_key_type` matches the real primary key** of your account table, and that column carries
  the unique index a foreign key needs. The migration asks this while it builds; nothing asks it
  again afterwards, so a configuration changed later goes unnoticed until an insert fails.
- **The identifier column still carries a unique index.** The migration creates one, or confirms
  the one you said you maintain — again, only while it runs. An account is looked up with
  `Repo.get_by/3`, so if that index is later dropped, two rows can share an identifier and the
  next sign-in raises `Ecto.MultipleResultsError` instead of letting anybody in.

And one is about something that looks like configuration and is not. `config :wax_, rp_id:` and
`origin:` are read by `wax_` as its own defaults, and this library never lets them be reached:
both are passed per call, so one application can serve a browser and a native client with
different answers. Setting them configures nothing here, and it sits in exactly the place you
would look. See
[decision 5](design.md#5-non-browser-clients-the-token-is-the-boundary-not-oauth2).

### What it needs

It starts your application, because most of the questions are about modules you own and an
unstarted application answers "no such thing" for all of them. So the environment it runs in has
to be a working one — a database it can reach, and configuration for that environment.

### Asking it yourself

`Ithibati.Doctor.examine/1` takes your application's name and answers as data. It needs no Mix, so
an application that would rather find out at boot than at the first ceremony can call it from its
own `Application.start/2`, or serve it from a health endpoint. The Mix task is a printer around
it.

## Credo checks

Two rules you can switch on in your own `.credo.exs`. They ship with this library and cost you
nothing if you do not name them — they are only defined when Credo is there to define them
against, so a release of yours does not carry them.

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
          {Ithibati.Credo.NoWaxConfiguration, []}
        ]
      }
    }
  ]
}
```

`Ithibati.Credo.NoDirectTableAccess` keeps this library's tables behind this library, and
`Ithibati.Credo.NoWaxConfiguration` reports the two `wax_` settings nothing here reads. Each
module carries its own reasoning, published here and shown by `mix credo explain`.

`NoDirectTableAccess` recognises a schema of ours wherever it is being read — piped into a repo,
joined into somebody else's query, passed to a repo called anything at all — and a table of ours
named as a string, resolved against the prefix you configured. What it cannot see is SQL inside a
string: `Repo.query!("select … from ithibati_tokens")` passes, and nothing here will tell you.

One thing to know about running them: `mix credo` does not compile first, so against a stale build
these checks are not loaded, Credo prints `Ignoring an undefined check`, and the run says "no
issues" having asked nothing. Put `compile` in front of it, the way your test alias already does.
