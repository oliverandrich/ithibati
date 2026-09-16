# Credo checks

Three rules you can switch on in your own `.credo.exs`. They ship with Ithibati and cost you
nothing if you do not name them: they are only defined when Credo is there to define them
against, so your release does not carry them.

A rule you have to switch on is a hint for somebody already being careful, not a boundary. These
report, and that is all they do.

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

- `Ithibati.Credo.NoDirectTableAccess` keeps Ithibati's tables behind Ithibati.
- `Ithibati.Credo.NoWaxConfiguration` reports the two `wax_` settings nothing here reads.
- `Ithibati.Credo.NoInternalCalls` reports a call to something Ithibati did not document, which
  is its way of saying that thing will change without notice.

Each module carries its own reasoning, published here and shown by `mix credo explain`.

`NoInternalCalls` leaves reflection alone. That means `__schema__/1`, `__struct__/0` and their
kind, but not an underscored name Ithibati marked itself, because the underscores say nothing about who
marked it. Two things it cannot see: a module whose documentation chunk was stripped at build
time answers nothing, so the rule reports nothing about it and a clean run looks the same; and a
bare name that two modules in one file alias differently is dropped instead of guessed at, so
that file loses a finding instead of gaining a wrong one.

`NoDirectTableAccess` recognises one of our schemas wherever it is read: piped into a repo,
joined into somebody else's query, passed to a repo called anything at all. It also recognises one of our
tables named as a string, resolved against the prefix you configured. It cannot see SQL inside a
string: `Repo.query!("select … from ithibati_sessions")` passes, and nothing will tell you.

One thing about running them: `mix credo` does not compile first. Against a stale build these
checks are not loaded, Credo prints `Ignoring an undefined check`, and the run reports no issues
having asked nothing. Put `compile` in front of it, the way your test alias already does.

Alongside them, [`mix ithibati.doctor`](doctor.md), which asks what a setup is missing.
