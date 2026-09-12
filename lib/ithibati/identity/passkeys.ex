defmodule Ithibati.Identity.Passkeys do
  @moduledoc """
  The WebAuthn ceremony: turning a browser's credential into an account's passkey.

  A challenge, the options the browser reads, and the verification that answers what to store. What
  verification returns is the account's credential — never a session. What is issued afterwards is
  a separate call to `Ithibati.Identity.Tokens`, and decision 5 in `docs/design.md` explains why
  that separation is what makes a device token additive rather than a rewrite.

  Which of the choices here are this library's and which an application's: decision 7.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Schema.User
  alias Ithibati.UserKey

  # WebAuthn Level 2, §5.1.3: a relying party must reject a credential id longer than 1023 bytes.
  # `Wax` does not — the length prefix is 16 bits, so an authenticator may claim up to 65535 — and
  # what arrives here is the browser's, which makes the size somebody else's choice.
  @credential_id_max 1023

  @doc """
  Mints a registration challenge for this relying party.

  `verify_trust_root: false` and `attestation: "none"` go together: nothing here polices
  authenticator models, so nothing here asks for an attestation it would not check — and an
  authenticator that honoured the request would be refused for its trouble.

  Everything this library's behaviour depends on is passed rather than left out.
  `Wax.Challenge.new/1` fills any option it was *not* given from `Application.get_all_env(:wax_)`,
  so a consumer who configures `wax_` directly would otherwise decide the relying party, how long a
  ceremony may take, and which attestation types are trusted — the last of which refuses every
  registration if it does not list `:none`.

  `:user_verification` is the one choice here that is an application's rather than this library's:
  whether the authenticator must confirm who is holding it. It defaults to `"preferred"`, and
  `registration_options/3` reads it back off the challenge so the browser can never be asked for
  something the server will refuse. `:seconds` is how long the challenge stays acceptable.
  """
  def registration_challenge(rp_id, origin, opts \\ [])
      when is_binary(rp_id) and is_binary(origin) do
    Wax.new_registration_challenge(
      rp_id: rp_id,
      origin: origin,
      verify_trust_root: false,
      attestation: "none",
      trusted_attestation_types: [:none],
      user_verification: Keyword.get(opts, :user_verification, "preferred"),
      timeout: Keyword.get(opts, :seconds, 60)
    )
  end

  @doc """
  Builds the browser's `PublicKeyCredentialCreationOptions`, binary fields base64url-encoded.

  Takes the account, or — before it exists — the identifier the invitation was addressed to. The
  only option is `:rp_name`, required, the name a passkey dialog shows.

  The credentials to exclude are read from this library's own table rather than passed in: their
  whole purpose is that one authenticator cannot enrol itself twice, and an argument that can be
  forgotten defeats it at exactly the call site that adds a second passkey.

  Three of the values are not negotiable and say why here rather than in the map. A **discoverable**
  credential is required — `required`, not `preferred`, because sign-in names no credential, so one
  the authenticator kept to itself would be invisible there, and a system with no passwords cannot
  leave the property it depends on to the authenticator's discretion. `requireResidentKey` is the
  same wish in the older spelling, which WebAuthn L2 asks for alongside it: a client implementing
  only L1 ignores `residentKey` and hands back a server-side credential that never appears at
  sign-in. And **`credProps`** is how the client answers a wish an authenticator may refuse;
  `verify_registration/4` is where that answer is acted on.

  The algorithms offered are ES256 and RS256, the two every authenticator in circulation supports.
  Ed25519 is deliberately absent rather than forgotten: nothing here has met an authenticator that
  offers it and not one of these two, and a list a consumer can extend is a published option this
  library has no caller for yet.
  """
  def registration_options(challenge, account_or_identifier, opts) do
    subject = subject(account_or_identifier)
    rp_name = Keyword.fetch!(opts, :rp_name)
    %{name: name, display_name: display_name} = User.credential_user(subject)

    %{
      challenge: url64(challenge.bytes),
      rp: %{id: challenge.rp_id, name: rp_name},
      user: %{id: url64(handle(subject)), name: name, displayName: display_name},
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      # `required`, not `preferred`: sign-in names no credential, so one the authenticator kept to
      # itself would be invisible there. A system with no passwords cannot leave the property it
      # depends on to the authenticator's discretion.
      #
      # `requireResidentKey` is the same wish in the older spelling, and WebAuthn L2 asks for both:
      # a client implementing only L1 ignores `residentKey` and hands back a server-side credential
      # that then never appears at sign-in.
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        # Read off the challenge, all three, so the browser cannot be asked for something the server
        # will refuse — the disagreement is silent and looks like a broken authenticator.
        userVerification: challenge.user_verification
      },
      extensions: %{credProps: true},
      excludeCredentials:
        Enum.map(existing_credentials(subject), &%{type: "public-key", id: url64(&1)}),
      attestation: challenge.attestation,
      timeout: challenge.timeout * 1000
    }
  end

  @doc """
  Verifies a registration and answers the credential to store.

  `discoverable` is the `credProps.rk` the client reported, and it has no default: every
  registration path has to hand one over, so a new one cannot be written that quietly skips the
  check — the compiler asks instead.
  """
  def verify_registration(attestation_object, client_data_json, challenge, discoverable) do
    with :ok <- check_discoverable(discoverable),
         {:ok, {auth_data, _attestation}} <-
           safe_wax(fn -> Wax.register(attestation_object, client_data_json, challenge) end),
         {:ok, credential} <- attested_credential(auth_data) do
      {:ok,
       %{
         key_id: credential.credential_id,
         public_key: :erlang.term_to_binary(credential.credential_public_key)
       }}
    end
  end

  @doc """
  The attributes of a credential to store, with whatever the browser called it.

  There is deliberately no third source for the name: naming the authenticator's make would mean
  mapping its AAGUID against a list nobody licenses. See decision 6.
  """
  def key_attrs(%{key_id: key_id, public_key: public_key}, label) do
    %{key_id: key_id, public_key: public_key, label: label}
  end

  # An authenticator that sets no attested-credential-data flag leaves this `nil`, and `Wax` does
  # not refuse it — the registration simply carries no credential. Matched rather than assumed:
  # the input is the browser's, and reading a field off `nil` would raise outside the rescue above,
  # which is the crash-with-a-stale-challenge this whole path exists to avoid.
  defp attested_credential(%{
         attested_credential_data: %Wax.AttestedCredentialData{} = credential
       }) do
    if byte_size(credential.credential_id) <= @credential_id_max,
      do: {:ok, credential},
      else: {:error, :credential_id_too_long}
  end

  defp attested_credential(_auth_data), do: {:error, :no_attested_credential}

  # An authenticator that says it did *not* store a discoverable credential is turned away here,
  # ahead of Wax: nothing about the attestation matters once the credential is one that sign-in can
  # never name, and the person is better told now than at their next visit, where the platform says
  # "no passkey available" and nothing explains it.
  #
  # Only an explicit `false` refuses. `nil` is a client that does not implement `credProps` — that
  # is silence, not a denial, and turning it away would lock out every browser that has not caught
  # up. `"false"` counts as the same denial: a form-encoded body, or anything routed through a DOM
  # attribute, hands over a string, and a guard matching the atom alone would wave it through with
  # the whole suite green.
  defp check_discoverable(reported) when reported in [false, "false"],
    do: {:error, :not_discoverable}

  defp check_discoverable(_reported), do: :ok

  # Checked the way every other entry point that takes an account checks it: an application with two
  # schemas using this library would otherwise build a ceremony against the wrong one's handle.
  defp subject(%_{} = account), do: Config.account!(account)

  # Through the same normalisation the identifier will go through when the account row is written,
  # so the derived handle is the same on a second attempt whatever case the invitation link carried.
  defp subject(identifier) when is_binary(identifier), do: User.normalize(identifier)

  # The account's own key once there is a row, and before that a value derived from the identifier
  # rather than a fresh random one: an authenticator replaces a discoverable credential only when
  # the relying party and this handle both match, so a random one would leave a second passkey
  # behind every time somebody cancels an invitation and opens it again.
  #
  # It is deliberately *not* the identifier itself — WebAuthn says a user handle must not be
  # personally identifying — and it does not agree with the account id that the same person gets
  # afterwards. Nothing here resolves a credential by handle; sign-in goes by credential id.
  defp handle(%_{id: id}), do: to_string(id)
  defp handle(identifier) when is_binary(identifier), do: :crypto.hash(:sha256, identifier)

  defp existing_credentials(%_{id: id}) do
    Config.repo().all(from k in UserKey, where: k.user_id == ^id, select: k.key_id)
  end

  defp existing_credentials(_identifier), do: []

  # Wax raises on some malformed input rather than answering; a caller gets the same error tuple
  # either way, because the alternative is a crash with a stale challenge left behind it.
  defp safe_wax(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  defp url64(value), do: Base.url_encode64(value, padding: false)
end
