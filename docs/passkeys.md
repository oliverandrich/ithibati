# Passkeys

Use `Ithibati.Identity.Passkeys` to add, list, rename and revoke credentials for an existing
account. Creating an account with its first credential is covered in
[Getting started](getting_started.md#5-the-handler).

```elixir
alias Ithibati.Identity.Passkeys

Passkeys.list_keys(account)
Passkeys.rename_key(account, id, "My work laptop")
Passkeys.delete_key(account, id)
```

`list_keys/1` returns the account's keys in stable, oldest-first order. Rename and delete return
`{:ok, key}` or `{:error, reason}`. A key belonging to another account is reported as
`:not_found`, just like a missing key.

## Adding a passkey through Phoenix

Use the registration ceremony with a signed-in account as its subject. Add the gate after
`fetch_session` in the ceremony pipeline so the handler can read `conn.assigns.current_account`:

```elixir
pipeline :ceremony do
  plug :accepts, ["json"]
  plug :fetch_session
  plug :protect_from_forgery
  plug Ithibati.Web.Gate, :current_account
end
```

The following callback clauses implement enrolment for existing accounts. In your handler,
alias `Ithibati.Identity.Passkeys` as `Passkeys` and import `Phoenix.Controller.json/2`:

```elixir
@impl true
def registration_subject(conn, _params) do
  case conn.assigns.current_account do
    nil -> {:error, :not_signed_in}
    account -> {:ok, account}
  end
end

@impl true
def register(conn, key_attrs, %MyApp.Accounts.User{} = account, params) do
  attrs = Passkeys.key_attrs(key_attrs, params["label"])

  case Passkeys.add_key(account, attrs) do
    {:ok, _key} -> {:ok, json(conn, %{status: "enrolled"})}
    {:error, reason} -> {:error, reason}
  end
end
```

Keep `authenticate/2` and `recovered/3` in the handler as well. This `registration_subject/2`
requires a signed-in account; an application supporting both new registration and enrolment
must branch between its two policies or use separate mounts and handlers.

Read the account from the authenticated connection. Looking up an account from a posted
username would let a caller enrol a passkey on another person's account.

Returning the account lets Ithibati populate `excludeCredentials` with its existing credentials.
The browser can then avoid registering one of those again.

From your page, push `ithibati:register`, optionally with `%{label: label}`. The hook returns
`ithibati:done` for the JSON response above; use that event to refresh the displayed keys.
The page needs the registration challenge and registration URL attributes described in
[The browser hook](ceremonies.md#the-javascript).

## Adding a passkey directly

Run registration with the existing account, then store only the verified result:

```elixir
with {:ok, verified} <- Passkeys.verify_registration(credential, challenge) do
  Passkeys.add_key(account, Passkeys.key_attrs(verified, "My phone"))
end
```

The surrounding challenge and transport flow is shown in
[Without the web half](ceremonies.md#without-the-web-half). `add_key/2` accepts the map from
verification directly; `key_attrs/2` adds an optional label. Never pass unverified client data
as the key attributes.

A passkey added without a label receives the default label `"Passkey"`. `add_key/2` returns
`{:error, :already_enrolled}` if the credential is already stored, including on another account.
If the account has been deleted before the insert, the function raises.

## Revoking a passkey

`delete_key/2` refuses the account's last passkey with `{:error, :last_key}`. This also holds
when two callers try to delete different keys concurrently: deletion locks the account row
before checking how many remain.

To allow removal of the final passkey explicitly:

```elixir
Passkeys.delete_key(account, id, last: :allow)
```

`last:` accepts `:refuse` (the default) or `:allow`; another value raises `ArgumentError`.
An account without passkeys depends on its [recovery codes](recovery.md) for access. Make that
consequence clear in the application's removal flow.
