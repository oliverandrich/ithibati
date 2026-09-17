# Recovery codes

Recovery codes provide access when a passkey is unavailable. A default batch contains twelve
codes, each usable for one sign-in. The application receives the plaintext batch when it is
issued; the database stores only SHA-256 digests.

```elixir
alias Ithibati.Identity.RecoveryCodes

RecoveryCodes.regenerate(account)
RecoveryCodes.remaining(account)
RecoveryCodes.redeem(code)
```

| Function | Result |
| --- | --- |
| `regenerate/2` | A new list of plaintext codes; all previous codes are invalidated |
| `remaining/1` | The number of unused codes |
| `redeem/2` | `{:ok, account, fresh_or_nil}` or `{:error, :invalid}` |

## Issuing and showing codes

Account creation normally issues the first batch through
`Ithibati.Identity.Grant.with_key_and_codes/3`. Retrieve `:recovery_codes` from the successful
transaction and show them to the person. [Getting started](getting_started.md#6-showing-the-recovery-codes)
provides a controller and template that clear the temporary session entry when rendering them.

To replace a batch later, call `regenerate/2` from an authenticated account-management flow:

```elixir
codes = RecoveryCodes.regenerate(account, count: 20)
```

Display the returned list and explain that the old codes no longer work. `count:` defaults to
twelve and accepts a non-negative integer. A count of zero invalidates the old batch and issues
no replacements; other invalid values raise `ArgumentError`.

Each code contains ten random bytes encoded as sixteen lowercase base32 characters. Treat the
plaintext batch as a credential: it belongs in the person's saved copy, not application logs.

## Redeeming a code

`redeem/2` spends the code and returns the account. It does not issue a session:

```elixir
case RecoveryCodes.redeem(code) do
  {:ok, account, nil} ->
    {:signed_in, account}

  {:ok, account, fresh} ->
    {:signed_in_with_new_codes, account, fresh}

  {:error, :invalid} ->
    {:error, :invalid_code}
end
```

These tagged results illustrate the three branches; your application chooses the resulting
session and response.

When the last unused code is spent, the same transaction issues a fresh batch. Preserve that
third return value and display it. If all passkeys are unavailable, spending the last code
without keeping its replacements can leave the user locked out when the current session ends.
The stored digests cannot recover the plaintext batch. This is why refill is enabled by default
and the web handler requires `recovered/3` to handle the result explicitly.

Concurrent redemptions lock the account row so the final count and refill are coordinated.

Disable automatic refill when your flow requires it:

```elixir
RecoveryCodes.redeem(code, refill: false)
```

An unknown code and a spent code both return `{:error, :invalid}`. The caller is not told
whether a submitted value was once valid.

## Signing in with one

The Phoenix mount includes `POST /recovery`, under the scope you chose. It takes a `code`,
redeems it and calls the required `recovered/3` handler callback.

In a handler that imports `json/2` and `put_session/3` and aliases `Ithibati.Web.Gate` as `Gate`:

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

The first clause follows normal sign-in. The second preserves and displays the new batch.
The redirect causes a full page load after the session is renewed.

Start recovery from a LiveView form:

```elixir
def handle_event("recover", %{"code" => code}, socket) do
  {:noreply, socket |> assign(error: nil) |> push_event("ithibati:recover", %{code: code})}
end
```

Set `data-recovery-url={~p"/auth/recovery"}` on the hook element. A rejected code returns
`ithibati:failed` with `invalid_code`. A browser exchange failure returns `recovery_failed`;
a lost response does not establish whether the server spent the code.

Recovery must be reachable by someone who cannot sign in. Apply application-level rate limiting
to this endpoint, as you do to sign-in. Ithibati does not track attempts or supply that limiter.

## Checking the flow

Verify that a code signs in once, fails on reuse, and stops working after regeneration.
Also exercise the last-code path: the fresh batch should appear, and the application should
retain no temporary display entry after it is read.
