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
    The callbacks an application implements, so the ceremony can ask it what to decide.

    Ithibati owns the WebAuthn ceremony: the challenge, its single use, the encoding, the
    verification. It owns none of what surrounds it. The application decides whether someone may
    register at all, what an account is made of, and what is issued once an assertion verifies. A
    library that answered those questions would be deciding that everyone wants a session cookie.

    You name an implementation in the router:

        scope "/auth" do
          ithibati_routes handler: MyAppWeb.Auth
        end
    """

    @typedoc "The account, or the identifier an invitation was addressed to before an account exists."
    @type subject :: struct() | String.t()

    @doc """
    Who is starting this registration.

    Ithibati calls this before it mints a challenge, so this is where an application refuses
    someone: a closed instance that already has its first account, or an invitation that was
    spent. It does not ask here what the dialog is called or how the ceremony is configured. Those
    are the same for every request a mount serves, so you give them to `ithibati_routes/1` once.

    Return the identifier as it will be *stored*, not as it was typed. The account row goes through
    `Ithibati.Schema.Identifier.normalize/1`, so approving the raw value puts `Ada` on the passkey
    dialog and `ada` in the table, and nothing reports the difference. A changeset answers both
    questions at once: whether the value is acceptable, and what it normalises to.

    **Return the account itself when it already has one.** Adding a second device is the same
    ceremony with the account in hand. `Ithibati.Identity.Passkeys.registration_options/3` fills `excludeCredentials` from an
    account and cannot fill it from an identifier. Approving the identifier there hands the browser
    an empty exclusion list, the browser re-offers a passkey that is already enrolled, and the
    person is refused only after completing the ceremony.
    """
    @callback registration_subject(Plug.Conn.t(), params :: map()) ::
                {:ok, subject()} | {:error, term()}

    @doc """
    Ithibati has verified the credential, and the application decides what to make of it.

    `key_attrs` is what `Ithibati.Identity.Passkeys.verify_registration/2` returned. Pass it to
    `Ithibati.Identity.Grant.with_key_and_codes/3` when you are creating an account, or to
    `Ithibati.Identity.Passkeys.add_key/2` when the account already exists. Ithibati cannot tell
    whether this is the first account of an instance or the acceptance of an invitation, and it
    does not try: that judgement needs what the application knows about its own instance. A
    second passkey on an existing account is the one it can tell apart, because you returned the
    account itself from `c:registration_subject/2`.

    Answer as you would in `c:authenticate/2`. `%{redirect: path}` means the same thing here.

    `subject` is what `c:registration_subject/2` approved. Ithibati carries it here from the
    challenge instead of re-reading it from `params`, because the browser sends the whole body
    again. An application that trusted `params` would validate an invitation for one identifier and
    enrol a credential against another.
    """
    @callback register(Plug.Conn.t(), key_attrs :: map(), subject(), params :: map()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Ithibati has verified the assertion, and this is the account.

    Ithibati has issued nothing. A session token behind a cookie, a long-lived token behind a
    bearer header, and a redirect to a second factor are all answers it deliberately does not pick.

    Answer in JSON. `%{redirect: path}` is the one key the shipped hook acts on: it follows the path
    with a full page load, which a sign-in needs anyway, because renewing the session takes the CSRF
    token with it. Anything else in the body reaches the LiveView as `ithibati:done`.
    """
    @callback authenticate(Plug.Conn.t(), account :: struct()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Somebody signed in with a recovery code instead of a passkey.

    This is the moment `authenticate/2` answers, reached the other way: an account whose holder has
    proved who they are. It is a separate callback because it carries a third thing.
    `Ithibati.Identity.RecoveryCodes.redeem/2` issues a fresh batch when the code just spent was
    the account's last unused one, and that batch is the only copy there will ever be. `fresh` is
    that list, or `nil` when there were codes left.

    Ithibati requires this callback instead of making it optional, and that is deliberate. An
    application that fell back to `authenticate/2` here would drop the batch in exactly the case it
    exists for: somebody has used their last code, nobody tells them, and the next lost passkey
    locks them out for good. You may delegate in one line, as long as you have made that choice
    deliberately.

        def recovered(conn, account, nil), do: authenticate(conn, account)
        def recovered(conn, account, fresh), do: # …show `fresh`, once

    Ithibati does not ask you to refuse anyone here. It answers both an unknown code and a spent
    one with `invalid_code` before it calls this, and deliberately does not tell them apart.
    """
    @callback recovered(Plug.Conn.t(), account :: struct(), fresh :: [String.t()] | nil) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Which relying party this request belongs to, as `{rp_id, origin}`.

    This callback is optional. Ithibati hands you the default instead of expecting you to replace
    it. `default` is the endpoint's configured `:url`, which is what the browser saw and not
    what this node accepted. Behind a proxy that terminates TLS the two disagree, and every
    ceremony fails on an origin mismatch. An implementation that dropped the default would have to
    re-derive exactly that, and people get that derivation wrong.

    So the usual shape adds to the default instead of replacing it:

        def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}

    The same passkey has to keep working in the browser. Implement this callback for a client whose
    origin is not that URL. Two of them: a native app's assertion arrives
    with the origin of an associated domain, an extension's arrives with the origin of the
    extension, and one relying-party id serves all of them. The application decides which origins
    it accepts, which is why Ithibati asks instead of reading configuration.

    The origin may be a list, and for an extension it usually is. The same extension has a
    different stable origin in each browser, `chrome-extension://<id>` and
    `moz-extension://<hash>`, and an assertion carries the one it was made at.

    > #### Never from the request {: .warning}
    >
    > Return values from a fixed set. If you read the `origin` request header and hand it back, the
    > check compares the client's claim against itself, so it matches whatever arrives. A credential
    > registered for the real site can then be asserted from any page its holder visits, and
    > WebAuthn loses its whole anti-phishing property. Nothing fails, in production or in your own
    > tests, because the origin always "matches".
    """
    @callback relying_party(Plug.Conn.t(), default :: {String.t(), String.t()}) ::
                {rp_id :: String.t(), origin :: String.t() | [String.t(), ...]}

    @optional_callbacks relying_party: 2
  end
end
