# `Phoenix.Component` is the sentinel for the whole web half, and every module under
# `lib/ithibati/web/` uses this same one. It lives in `phoenix_live_view`, which is the narrowest of
# the three optional dependencies — so if it is there, `phoenix` and `plug` are too, and the web
# half can be taken or left as one piece rather than in parts.
#
# It is one piece on purpose. Splitting it finer, so that a consumer could have Phoenix without
# LiveView, cost a nested guard, a second example, and a class of mistake this library cannot see:
# a private function used only from the LiveView half compiles away to dead code in that build and
# warns in somebody else's, never in ours.
#
# The guard has to be here rather than in `elixirc_paths`, which `project/0` reads — and a
# dependency's `project/0` can see nothing about the project being built. This check runs when the
# module compiles, by which point a consumer's dependencies are loaded.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Handler do
    @moduledoc """
    What an application decides, in the places the ceremony has to ask it.

    This library owns the WebAuthn ceremony — the challenge, its single use, the encoding, the
    verification — and none of what surrounds it. Whether someone may register at all, what an
    account is made of, and what is issued once an assertion verifies are the application's, and a
    library that answered them would be deciding that everyone wants a session cookie.

    An implementation is named in the router:

        scope "/auth" do
          ithibati_routes handler: MyApp.Auth
        end
    """

    @typedoc "The account, or — before one exists — the identifier an invitation was addressed to."
    @type subject :: struct() | String.t()

    @doc """
    Who is starting this registration.

    Called before a challenge is minted, so refusing here is how an application says "not you" —
    a closed instance that already has its first account, an invitation that was spent. What the
    dialog is called and how the ceremony is configured are not asked here: those are the same for
    every request a mount serves, so they are given to `ithibati_routes/1` once.

    Return the identifier as it will be *stored*, not as it was typed:
    `Ithibati.Schema.Identifier.normalize/1` is what the account row goes through, so approving the
    raw value puts `Ada` on the passkey dialog and `ada` in the table, and nothing fails to say so.
    A changeset answers both questions at once — whether the value is acceptable, and what it
    normalises to.

    **Return the account itself when it already has one.** Adding a second device is the same
    ceremony with the account in hand, and `registration_options/3` fills `excludeCredentials`
    from an account and cannot from an identifier — so approving the identifier there hands the
    browser an empty exclusion list, it re-offers a passkey already enrolled, and the person is
    refused only after completing the ceremony.
    """
    @callback registration_subject(Plug.Conn.t(), params :: map()) ::
                {:ok, subject()} | {:error, term()}

    @doc """
    The credential verified; make of it what the application makes of it.

    `key_attrs` is what `Ithibati.Identity.Passkeys.verify_registration/2` returned, ready for
    `Ithibati.Identity.Grant.with_key_and_codes/3` when an account is being created, or for
    `Ithibati.Identity.Passkeys.add_key/2` when it already exists. Whether that becomes the first
    account of an instance, the acceptance of an invitation, or a second passkey on an account
    that already has one is not something this library can tell, and decision 3 in
    `docs/design.md` is why it does not try.

    On answering, see `c:authenticate/2` — `%{redirect: path}` means the same thing here.

    `subject` is what `c:registration_subject/2` approved, carried here from the challenge rather
    than re-read from `params`: the browser sends the whole body again, so an application that
    trusted `params` would have validated an invitation for one identifier and enrolled a credential
    against another.
    """
    @callback register(Plug.Conn.t(), key_attrs :: map(), subject(), params :: map()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    The assertion verified; this is the account.

    Nothing has been issued. A session token behind a cookie, a long-lived token behind a bearer
    header, or a redirect to a second factor are all answers this library deliberately does not
    pick — see decision 5 in `docs/design.md`.

    Answer in JSON, and `%{redirect: path}` is the one key the shipped hook acts on: it follows it
    with a full page load, which a sign-in needs anyway because renewing the session takes the CSRF
    token with it. Anything else in the body reaches the LiveView as `ithibati:done`.
    """
    @callback authenticate(Plug.Conn.t(), account :: struct()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Which relying party this request belongs to, as `{rp_id, origin}`.

    Optional. The default is handed to it rather than replaced by it: `default` is the endpoint's
    configured `:url`, which is what the browser saw rather than what this node accepted — behind a
    proxy terminating TLS those disagree and every ceremony fails on an origin mismatch. An
    implementation that dropped it would have to re-derive exactly that, which is the derivation
    people get wrong.

    So the usual shape is to add rather than replace:

        def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}

    The same passkey has to keep working in the browser, after all. Implement it for a client whose
    origin is not that URL. `docs/design.md` names two: a native
    app's assertion arrives with the origin of an associated domain, an extension's with the origin
    of the extension, and one relying-party id serves all of them. Which origins an application
    accepts is the application's decision, which is why this is asked rather than configured.

    The origin may be a list, and for an extension it usually is: the same extension has a
    different stable origin in each browser — `chrome-extension://<id>` and
    `moz-extension://<hash>` — and an assertion carries the one it was made at.

    > #### Never from the request {: .warning}
    >
    > Return values chosen from a fixed set. Reading the `origin` request header and handing it back
    > makes the check compare the client's claim against itself, so it matches whatever arrives: a
    > credential registered for the real site can then be asserted from any page its holder visits,
    > and WebAuthn's whole anti-phishing property is gone. Nothing fails, in production or in a
    > consumer's tests, because the origin always "matches".
    """
    @callback relying_party(Plug.Conn.t(), default :: {String.t(), String.t()}) ::
                {rp_id :: String.t(), origin :: String.t() | [String.t(), ...]}

    @optional_callbacks relying_party: 2
  end
end
