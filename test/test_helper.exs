# Credo caches parsed ASTs in a GenServer, so a test that parses a source needs its application up,
# and `runtime: false` means nothing starts it for us. The result is deliberately not matched: under
# `mix precommit`, `mix credo` has already run in this VM and left the application stopped with its
# supervisor alive, and `ensure_all_started/1` then returns an error tuple rather than `{:ok, []}`.
# Measured in both directions — matching on `{:ok, _}` turns the gate red while a bare `mix test`
# stays green, and dropping the call entirely does the exact opposite.
_ = Application.ensure_all_started(:credo)

ExUnit.start()
