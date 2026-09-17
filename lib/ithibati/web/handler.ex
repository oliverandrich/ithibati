# `Phoenix.Component` is the sentinel for the optional web layer: it comes with LiveView,
# which depends on Phoenix and Plug. Keep the guard in each web module so it is evaluated
# when dependencies are available, rather than while Mix reads `project/0`.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Handler do
    @moduledoc """
    Defines the application's decisions during registration, authentication and recovery.

    Implement all four required callbacks and name the handler in the router:

        ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"

    `registration_subject/2` approves a registration before a challenge is issued. `register/4`
    stores its verified credential. `authenticate/2` and `recovered/3` decide what a verified
    account receives, such as a session and redirect.

    The optional `relying_party/2` callback selects trusted relying-party values for clients whose
    origins differ from the endpoint URL. [Registering and signing in](ceremonies.md) covers the
    complete HTTP and browser flow.
    """

    @typedoc "An existing account struct or an approved identifier for a new account."
    @type subject :: struct() | String.t()

    @doc """
    Approves the registration subject before Ithibati issues a challenge.

    Return `{:ok, identifier}` for a new account or `{:ok, account}` when enrolling another passkey
    on an existing account. Return `{:error, reason}` to refuse registration.

    Validate and normalize new identifiers through the application's changeset before returning
    them. This keeps the passkey dialog's name consistent with the value later stored.

    For an existing account, establish authorization from the authenticated connection. Do not
    look up the account solely from a posted identifier. Returning the account also lets Ithibati
    include its current credentials in the browser's exclusion list.

    Mount options such as `:rp_name` and challenge lifetime belong in `ithibati_routes/1`.
    """
    @callback registration_subject(Plug.Conn.t(), params :: map()) ::
                {:ok, subject()} | {:error, term()}

    @doc """
    Stores the result of a successful registration verification.

    `key_attrs` contains the verified credential. `subject` is the identifier or account returned
    by `c:registration_subject/2` and retained with the challenge. `params` is the final request's
    body, which may differ from the parameters supplied at the challenge step.

    Use `Ithibati.Identity.Grant.with_key_and_codes/3` when creating an account, or
    `Ithibati.Identity.Passkeys.add_key/2` when adding a passkey to an existing account.

    Build the account from `subject`, not a newly posted identifier or a replacement invitation
    in `params`. Otherwise the second request could change which account the approved ceremony
    creates.

    Return `{:ok, conn}` or `{:error, reason}`. Use the JSON response conventions described in
    `c:authenticate/2`, including a `redirect` field when the browser should navigate.
    """
    @callback register(Plug.Conn.t(), key_attrs :: map(), subject(), params :: map()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Decides what to issue after a passkey assertion identifies an account.

    Ithibati passes the configured account struct and has not issued a session or other token.
    The application may call `Ithibati.Web.Gate.log_in/2`, issue its own credential, or require
    another authentication step.

    Return `{:ok, conn}` or `{:error, reason}`. Send JSON when providing a response. A JSON
    `redirect` field makes the shipped hook perform a full page load; other successful bodies
    reach the LiveView as `ithibati:done`. If the connection has no sent response, the controller
    supplies its default status JSON.

    After `Gate.log_in/2`, finish with a full page load so the page obtains the renewed session's
    CSRF token. An HTTP redirect response does not replace the JSON redirect field.
    """
    @callback authenticate(Plug.Conn.t(), account :: struct()) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Decides what to issue after a recovery code identifies an account.

    The code is already spent when this callback runs. `fresh` is a new plaintext code batch when
    the last unused code triggered a refill, or `nil` when codes remained.

    Return `{:ok, conn}` or `{:error, reason}` using the response conventions of `c:authenticate/2`.
    When `fresh` is `nil`, delegating to `authenticate/2` is sufficient. Otherwise, preserve the
    batch for display as part of the response flow. The stored digests cannot recover it later.

    The controller refuses unknown or spent codes with `invalid_code` before invoking this
    callback. Refusing in the callback does not undo redemption or recover the spent code.
    See [Recovery codes](recovery.md#signing-in-with-one) for a complete implementation.
    """
    @callback recovered(Plug.Conn.t(), account :: struct(), fresh :: [String.t()] | nil) ::
                {:ok, Plug.Conn.t()} | {:error, term()}

    @doc """
    Returns the trusted `{rp_id, origin}` used to create a challenge for this request.

    This callback is optional. `default` contains the host and origin derived from the endpoint's
    configured public URL. These values can differ from the node's connection behind a
    TLS-terminating proxy.

    Return an origin string or a non-empty list of accepted origins. To retain the browser origin
    while adding application-defined trusted client origins:

        def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}

    Client-specific support also depends on the extension or native application's WebAuthn
    integration. Keep the relying-party ID stable for existing credentials.

    > #### Choose trusted values {: .warning}
    >
    > Select values from a fixed set controlled by the application. Reflecting the request's
    > `origin` header would make verification compare the client's claim with itself.
    """
    @callback relying_party(Plug.Conn.t(), default :: {String.t(), String.t()}) ::
                {rp_id :: String.t(), origin :: String.t() | [String.t(), ...]}

    @optional_callbacks relying_party: 2
  end
end
