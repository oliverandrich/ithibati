# Passkeys

What an account can do with the credentials it already has, once
[registering](ceremonies.md) has put one there.

## The passkeys an account has

`Ithibati.Identity.Passkeys` enrols, lists, renames and revokes them:

```elixir
Passkeys.add_key(account, Passkeys.key_attrs(verified, "My phone"))
Passkeys.list_keys(account)                       # oldest first, stable order
Passkeys.rename_key(account, id, "My work laptop")
Passkeys.delete_key(account, id)
```

Adding a second device runs the same ceremony as the first, except that you already have the
account: mint a challenge with
[`registration_challenge/3`](`Ithibati.Identity.Passkeys.registration_challenge/3`), hand
[`registration_options/3`](`Ithibati.Identity.Passkeys.registration_options/3`) to the
browser, verify the answer with
[`verify_registration/2`](`Ithibati.Identity.Passkeys.verify_registration/2`), then call
[`add_key/2`](`Ithibati.Identity.Passkeys.add_key/2`).

`verify_registration/2` answers `{:ok, %{key_id: …, public_key: …}}`, which `add_key/2` takes as
it is. [`key_attrs/2`](`Ithibati.Identity.Passkeys.key_attrs/2`) is how you put a name on it first
— the snippet above passes what the
verification returned, with a label the person chose.
[`with_key_and_codes/3`](`Ithibati.Identity.Grant.with_key_and_codes/3`) is the other one — it
builds the account; `add_key/2` writes one row onto
an account that already exists.

### Through the web half

The ceremony routes handle this too, and the branch is in your handler. Return the account from
[`registration_subject/2`](`c:Ithibati.Web.Handler.registration_subject/2`) instead of an
identifier, and [`register/4`](`c:Ithibati.Web.Handler.register/4`) calls `add_key/2` instead of
building one:

```elixir
@impl true
def registration_subject(conn, _params) do
  case conn.assigns.current_account do
    nil -> {:error, :not_signed_in}
    account -> {:ok, account}
  end
end

@impl true
def register(conn, key_attrs, %MyApp.Accounts.User{} = account, _params) do
  case Passkeys.add_key(account, key_attrs) do
    {:ok, _key} -> {:ok, json(conn, %{status: "enrolled"})}
    {:error, reason} -> {:error, reason}
  end
end
```

> #### Whose account is being enrolled? {: .warning}
>
> Read the account off the connection, never off the parameters. A handler that looks up
> whatever identifier was posted and hands that account back turns `/registration` into passkey
> enrolment on somebody else's login: anybody who can reach the endpoint adds a credential to
> any account they can name, and from then on they are that person.
>
> `registration_subject/2` is asked before a challenge is minted precisely so this refusal costs
> nothing. Signed in, enrol on yourself; not signed in, refuse.

Naming the new credential is the other thing this branch decides: `register/4` receives
`key_attrs` already built, so pass it through `Passkeys.key_attrs/2` with a label somebody chose
if you want one. A passkey enrolled without one shows up in
[`list_keys/1`](`Ithibati.Identity.Passkeys.list_keys/1`) unnamed, and
[`rename_key/3`](`Ithibati.Identity.Passkeys.rename_key/3`) is then the only way to label it.

`add_key/2` answers `{:error, :already_enrolled}` when that credential is on the account
already. You get the same answer when it sits on *somebody else's* account, because a credential
identifies a device rather than a person.

It should be rare here, and that is worth one sentence: when `registration_subject/2` hands back
the account rather than an identifier — which it can, once the account exists —
`registration_options/3` puts that account's credentials in `excludeCredentials`, and a browser
that honours it never offers an authenticator it has already enrolled. Registering a *first*
passkey has no account to name, so that list is empty and the unique index is what answers.

If the account is deleted between the ceremony and the write, `add_key/2` raises rather than
returning an error, the same way minting a token does.

Every function here is scoped to the account you pass. `list_keys/1` returns only that account's
keys, and the two that take an id return `{:error, :not_found}` for a key belonging to somebody
else instead of reaching their row. You cannot rename a key onto another account.

## The last passkey

[`delete_key/3`](`Ithibati.Identity.Passkeys.delete_key/3`) refuses the last one with `{:error,
:last_key}`.

That is not a lockout on its own, because recovery codes still reach the account:
`POST /recovery` is mounted with the other routes, so somebody with no passkeys can still get
in. It is the step that makes a lockout possible. Afterwards a single sheet of one-time codes is
the only way, and the codes run out.

The third argument overrides the refusal:

```elixir
Passkeys.delete_key(account, id, last: :allow)
```

`last:` takes `:refuse`, which is the default, or `:allow`. Any other value raises
`ArgumentError`.

The refusal also holds when two passkeys are deleted at the same moment, which takes more than
counting rows: the account's row is locked first, so the second deletion sees what the first
committed rather than the snapshot it started from.
