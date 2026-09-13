# Guarded for the same reason as its neighbours: a consumer who took this library without Phoenix
# must still get a core that compiles, and `Plug.Conn` is not there to be named.
if Code.ensure_loaded?(Plug.Conn) do
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
    """
    @callback registration_subject(Plug.Conn.t(), params :: map()) ::
                {:ok, subject()} | {:error, term()}

    @doc """
    The credential verified; make of it what the application makes of it.

    `key_attrs` is what `Ithibati.Identity.Passkeys.verify_registration/2` returned, ready for
    `Ithibati.Identity.Grant.with_key_and_codes/3`. Whether that becomes the first account of an
    instance, the acceptance of an invitation, or a second passkey on an account that already
    exists is not something this library can tell, and decision 3 in `docs/design.md` is why it does
    not try.

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
    """
    @callback authenticate(Plug.Conn.t(), account :: struct()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}
  end
end
