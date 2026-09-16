# Recovery codes

An account with only passkeys has one credential set, and a lost keychain would be the end of it.
Recovery codes are the second set: twelve by default, shown once, each good for one sign-in.

```elixir
alias Ithibati.Identity.RecoveryCodes

RecoveryCodes.regenerate(account)   # ["…", …] — the plaintext, once
RecoveryCodes.remaining(account)    # how many are left unspent
RecoveryCodes.redeem(code)          # {:ok, account, fresh_or_nil} | {:error, :invalid}
```

The rows hold sha256 digests. Nothing recovers the plaintext afterwards, so the moment the codes
are issued is the only moment anybody can write them down. Say that on the page that shows them.

A code is ten random bytes in lower-case base32. Sixteen characters from an alphabet of
thirty-two, so eighty bits, which is why guessing is not the threat model. Reading over
somebody's shoulder is.

## Issuing them

A first batch and a fresh batch are the same call.
[`regenerate/2`](`Ithibati.Identity.RecoveryCodes.regenerate/2`) invalidates every code the
account had, spent or not, and returns the new ones. The second argument says how many:

```elixir
RecoveryCodes.regenerate(account, count: 20)
```

`count:` defaults to twelve and takes any non-negative integer. Anything else raises
`ArgumentError`.

The first batch usually arrives with the account, not from a separate call.
`Ithibati.Identity.Grant.with_key_and_codes/3` appends both the passkey and the codes to the
transaction that creates it, so an account never exists without a way back in. [Invitations, and
the first account](invitations.md) shows that composition.

## Spending one

[`redeem/2`](`Ithibati.Identity.RecoveryCodes.redeem/2`) marks the code spent and returns the
account that held it. It is a sign-in route, not
only a repair: what you do with the account afterwards is what you do after a successful
assertion.

It returns three elements, not two:

```elixir
case RecoveryCodes.redeem(code) do
  {:ok, account, nil} -> sign_in(account)
  {:ok, account, fresh} -> sign_in(account) && show_once(fresh)
  {:error, :invalid} -> refuse()
end
```

`fresh` is a new batch when this was the account's **last** unused code, and `nil` otherwise. It
is three elements so that a caller cannot match the common case and silently drop the batch in
the one case it exists for. The refill happens in the same transaction, and the second argument
turns it off:

```elixir
RecoveryCodes.redeem(code, refill: false)
```

It is on by default because of how the failure looks. An account with no passkey and no codes
left is locked out of a self-hosted instance for good, and the only moment anybody can write down
a new batch is the one where they have just used the last old one. Two codes spent at the same
instant are settled by locking the account's row first, so the second redemption counts what
the first committed and the refill happens once.

## Signing in with one

[`ithibati_routes/1`](`Ithibati.Web.Router.ithibati_routes/1`) mounts a fifth endpoint, `POST
/recovery`, for exactly this. It takes a
`code`, spends it, and calls `c:Ithibati.Web.Handler.recovered/3` on your handler, the same
place a verified assertion arrives, reached the other way:

```elixir
@impl true
def recovered(conn, account, nil), do: authenticate(conn, account)

def recovered(conn, account, fresh) do
  {:ok,
   conn
   |> Gate.log_in(account)
   |> put_session(:recovery_codes, fresh)
   |> json(%{redirect: "/recovery-codes"})}
end
```

The two clauses are the whole of it: no fresh batch, sign them in the way you always do; a fresh
batch, show it once on the page you already have from registration.

`POST /recovery` is unauthenticated by nature, because somebody who cannot sign in is the
person using it, so rate limiting is yours the way it is for your sign-in page. Ithibati refuses an unknown
code and a spent one identically and counts nothing.

The browser half is a form and a `push_event`, because the endpoint answers JSON and sets a
session cookie, which a LiveView cannot do:

```elixir
def handle_event("recover", %{"code" => code}, socket) do
  {:noreply, socket |> assign(error: nil) |> push_event("ithibati:recover", %{code: code})}
end
```

The hook element needs `data-recovery-url={~p"/auth/recovery"}` alongside the other four. A
refusal arrives as `ithibati:failed` with `invalid_code`.

## What it will not tell you

`{:error, :invalid}` covers both a code nobody holds and a code already spent, and it does not
say which. Distinguishing them would tell somebody holding a stolen sheet which of their guesses
were once real.
