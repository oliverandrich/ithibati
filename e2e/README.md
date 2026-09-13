# The browser tests

`priv/static/ithibati.js` is the half of this library that runs on somebody else's machine, and
until this directory existed nothing executed a line of it. What the Elixir suite can check is that
the file contains the right hook name; what it cannot check is whether a ceremony completes, whether
a missing attribute is reported as itself, or whether the CSRF token is on the request.

These tests drive the two applications under `../examples` in a real browser, against a real
WebAuthn ceremony. They are the same pages a person clicks, so they also keep the examples honest.

## Running them

Needs Postgres — the same one the examples need — and a browser Playwright downloads once.

```
mise run e2e
```

That prepares both examples — their dependencies and, importantly, their asset bundles — installs
the packages, fetches Chromium and runs the suite. It is what CI runs too, so the two cannot drift.

Afterwards, from this directory, `npm test` alone is enough while the examples are already built,
and `npm run report` opens the last HTML report. If the library's JavaScript changed since, run
`mise run e2e` again rather than `npm test`: see the first of the two traps below.

The suite starts both examples itself, in the **test** environment under `MIX_TEST_PARTITION=e2e`,
so it uses `*_teste2e` databases: it cannot disturb `mix test`, and it never touches the `*_dev`
database you were clicking through a minute ago.

## Chromium only, and why that is not a preference

The tests need a virtual authenticator, and the one that works here is Chrome DevTools Protocol's.
Playwright 1.63 ships `browserContext.credentials`, which is cross-browser and much nicer to read —
but it cannot serve this library, and the reason is worth writing down because the next person to
try it will get the same puzzling failure:

`credentials.install()` replaces `navigator.credentials` with a JavaScript object whose
`clientDataJSON` and `attestationObject` are ordinary properties. The native
`PublicKeyCredential.prototype.toJSON` reads internal slots rather than properties, so on that
object it answers `{id, rawId, type, response: {}}` — an empty response — and
`getClientExtensionResults()` answers `{}`. This library serialises with `toJSON()` and reads
`credProps.rk` out of the extension results (decision 7 in `docs/design.md`), so every ceremony
arrives at the server as `malformed_credential`. That is the test double failing, not the code under
test.

CDP's authenticator lives inside Chrome's own WebAuthn implementation, so the page receives a
genuine credential. The cost is `browserContext.newCDPSession`, which answers *"CDP session is only
available in Chromium"* in Firefox and WebKit. Safari's behaviour therefore goes unchecked here; if
that becomes the thing worth knowing, it is a manual run, not a green tick.

## What is covered

| | |
|---|---|
| `tests/open_registration.spec.js` | A passkey is made, twelve codes are shown once, and the same passkey signs back in with no username typed. |
| `tests/invitation_only.spec.js` | The first account claims the instance; an invitation is written, accepted, and answers like an invented one once spent. |
| `tests/hook_failures.spec.js` | The four reasons the hook distinguishes: a missing data attribute by name, a non-JSON response by status, a dismissed dialog as cancelled, and a refusal the server named in its own words. |

Every assertion goes through the page, never through an internal: what is checked is the sentence a
person reads, which covers the hook, the LiveView round trip and the application's own vocabulary at
once.

## Two things that will trip you up

**The examples bundle the library's JavaScript.** `esbuild` inlines `priv/static/ithibati.js` into
each example's `app.js`, so editing the library and re-running the tests changes nothing until
`mix assets.build` has run in the example. A control check that skips this measures the old bundle
and reports, convincingly, that nothing is guarded.

**The servers run on a sandbox pool.** `config/test.exs` sets
`pool: Ecto.Adapters.SQL.Sandbox`, and the e2e servers inherit it, because running in `MIX_ENV=test`
is what keeps this from compiling everything a second time. It works because the sandbox is in
automatic mode unless something calls `Sandbox.mode(:manual)`, which only `test_helper.exs` does and
only under `mix test`. Worth knowing, because if that ever stops being true the symptom is a
checkout that hangs rather than an error that says so.

**LiveView puts back what you take away.** Several tests spoil a `data-` attribute on the ceremony
element. Do it *after* the last thing that triggers `phx-change`, or the DOM patch restores the
attribute and the test fails for an unrelated reason.
