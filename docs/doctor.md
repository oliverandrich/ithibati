# `mix ithibati.doctor`

Checks everything Ithibati needs your application to have got right, and reports on each one.
`Ithibati.Doctor` explains why it exists; this page is about running it.

```console
$ mix ithibati.doctor
ok   config :ithibati, user_schema:
    MyApp.Accounts.User
bad  this library's tables
    ithibati_keys, ithibati_recovery_codes, ithibati_sessions, ithibati_bootstrap are missing — run
    this library's migration, or check `config :ithibati, table_prefix:` against what it created.
bad  the identifier's unique index
    users.email carries no unique index. Two registrations of the same identifier at the same
    moment both pass the changeset and both insert, and the identifier then names two accounts.
skip the invitation table
    no invitation schema to ask about
...
** (Mix) 2 things to fix.
```

There are twelve checks. A healthy run ends with `Nothing to fix.` and exits zero, so you can put it
in your own gate:

```elixir
# mix.exs
defp aliases do
  [precommit: ["compile --warnings-as-errors", "ithibati.doctor", "test"]]
end
```

## The checks only this can make

Most of them are about configuration, and the doctor asks by calling the same code that refuses
at run time. Six have nowhere else to live.

- **The repo answers.** Being configured means the module exists and is an Ecto repo. It does not
  mean it is in your supervision tree, or that its database is up.
- **Ithibati's tables exist.** An application that configured everything and never ran the
  migration passes every other check and fails at the first ceremony. If you changed
  `table_prefix:` *after* migrating, this is where you find out.

  Two different prefixes meet here, and the check involves both. `config :ithibati,
  table_prefix:` is part of the **table name**. It is what makes the tables `ithibati_keys` and
  friends, and `"auth"` would make them `auth_keys`. A Postgres **schema** prefix is the other
  one, and the doctor looks in whichever your repo migrates into by default. So if you migrate
  into a schema chosen per run, as `mix ecto.migrate --prefix tenant1` does, it says which schema it
  looked in, and you are being told about tables it was not looking at.
- **`users_key_type` matches the real primary key** of your account table, and that column
  carries the unique index a foreign key needs. The migration checks this while it builds and
  nothing checks it again, so a configuration changed afterwards goes unnoticed until an insert
  fails.
- **The identifier column still carries a unique index.** The migration creates it, or confirms
  the one you said you maintain, and again only while it runs. If that index is dropped later,
  two concurrent registrations of the same identifier both pass the changeset and both insert.

- **The invitation table, if you configured one.** Whether it is there, and whether `token_hash`
  carries the unique index the token in a link is looked up by. This is the one check nothing
  else can make: an application that turns invitations on *after* running the migration never
  runs it again, so the table it just wrote is checked here or nowhere.
- **Your handler implements all four callbacks.** It finds the handler by walking your
  application's modules for the one that declares `Ithibati.Web.Handler`, so it does not need
  to be told. A missing callback is a compiler warning, so an application not built with
  `--warnings-as-errors` compiles, migrates, boots and serves, and then fails inside a
  ceremony. [`recovered/3`](`c:Ithibati.Web.Handler.recovered/3`) is the one to forget, because it
  arrived after the
  other three.

One is about something that looks like configuration and is not. `wax_` reads
`config :wax_, rp_id:` and `origin:` as its own defaults, and Ithibati never lets them be
reached: both are passed per call, so one application can serve a browser and a native client
with different answers. Setting them configures nothing here, and they sit in exactly the place
you would look, which is why the doctor says so.

## What it needs

It starts your application, because most of the checks are about modules you own and an unstarted
application answers "no such thing" for all of them. The environment it runs in has to be a
working one: a database it can reach, and configuration for that environment.

## Calling it yourself

`Ithibati.Doctor.examine/1` takes your application's name and returns the answers as data. It
needs no Mix, so an application that would rather find out at boot than at the first ceremony can
call it from `Application.start/2`, or serve it from a health endpoint. The Mix task is a printer
around it.

Alongside it, [the Credo checks](credo.md) a consuming project can switch on.
