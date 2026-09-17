# Setup checks

Run `mix ithibati.doctor` in the consuming application after configuring Ithibati and running
migrations. It starts your application and checks the integration against its database.

```console
$ mix ithibati.doctor
```

A healthy run ends with `Nothing to fix.` and exits zero. Failures are labelled `bad`; optional
checks that do not apply are labelled `skip`. Fix the reported setup and rerun the command.

## What it checks

The doctor combines configuration validation with checks that require a running application:

| Area | What to check when it fails |
| --- | --- |
| Account configuration | `user_schema` names the expected schema and `repo` names the Ecto repo |
| Database connection | The repo is started and its database is reachable |
| Ithibati tables | Migrations ran with the same table-name prefix used by the compiled schemas |
| Account primary key | The database column matches `users_key_type` and has the required uniqueness |
| Account identifier | The column exists and has the required unique index |
| Invitation table | When configured, the table exists and `token_hash` has its unique index |
| Handler callbacks | Each discovered handler implements the four required callbacks |
| Mounted handlers | Router mounts refer to available handler modules |
| Session validity | The value uses a positive count and a supported unit |
| WebAuthn configuration | No unused `wax_` origin or RP-ID settings are misleading the integration |

The complete set is defined in `Ithibati.Doctor`; this table groups related checks by the action
you can take. [Configuration and schemas](configuration.md) explains the settings and indexes.

## Common fixes

### Missing tables or an unexpected prefix

Run your migrations against the same database the application uses. `table_prefix: "auth"`
means names such as `auth_sessions`; it does not select a PostgreSQL schema.

The doctor uses the repo's default migration schema prefix. If you migrated with an explicit
`mix ecto.migrate --prefix tenant1`, compare that with the schema named in the report.

### Missing identifier index

A changeset validation alone cannot prevent concurrent registrations from storing the same
identifier. Restore the unique index required by the account schema. If you chose
`unique_index: false`, your own migration must maintain it.

### Invitations enabled after initial setup

Ithibati's original migration is already recorded as applied. Creating the invitation table
later must also create its token index. Use `Ithibati.Migration.invitation_index(version: 1)`
in that migration, as shown in the [invitation guide](invitations.md#2-configure-and-migrate).

### Missing handler callback

Implement `registration_subject/2`, `register/4`, `authenticate/2` and `recovered/3`.
The recovery callback must handle both `nil` and a fresh code batch. See
[Recovery codes](recovery.md#signing-in-with-one).

### Unused `wax_` settings

Ithibati passes the relying-party ID and origin explicitly. Configure the endpoint's public
URL or implement the handler's optional `relying_party/2` callback, as described in
[The relying party](ceremonies.md#the-relying-party).

## Add it to a check command

In your application's `mix.exs`, include the doctor in a check alias after compilation:

```elixir
defp aliases do
  [precommit: ["compile --warnings-as-errors", "ithibati.doctor", "test"]]
end
```

Merge this into your existing aliases. The environment running it needs working application
configuration, a started repo and a reachable, migrated database.

For a programmatic result, call `Ithibati.Doctor.examine/1` with the application's name. It
returns the findings as data without requiring Mix. Call it once the relevant application
processes and repo are available.

## What to verify separately

The doctor checks installation state. It does not exercise templates, asset imports, browser
passkey prompts or your application's authorization policy. Complete the browser flow at the
end of [Getting started](getting_started.md#10-check-it-then-run-it) as well.

[Credo checks](credo.md) complement it by inspecting integration code.
