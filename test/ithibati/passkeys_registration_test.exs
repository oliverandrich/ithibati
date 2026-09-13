defmodule Ithibati.Identity.PasskeysRegistrationTest do
  @moduledoc """
  The registration half of the ceremony, driven with a credential and an attestation object built
  here rather than with a stand-in — see `Ithibati.Credentials`.

  Not async: two of these move `wax_`'s own application environment, which every call into Wax
  reads, to prove that the relying party stays a per-call argument.
  """
  use Ithibati.DataCase, async: false

  alias Ithibati.Identity.Passkeys

  @rp_id "localhost"
  @origin "http://localhost:4000"
  @rp_name "A Consuming Application"

  describe "registration_challenge/2" do
    test "carries the relying party it was given" do
      challenge = Passkeys.registration_challenge(@rp_id, @origin)

      assert challenge.rp_id == @rp_id
      assert challenge.origin == @origin
    end

    # `Wax.Challenge.new/1` merges `Application.get_all_env(:wax_)` over what it is passed, so a
    # consumer who configures the library it depends on would otherwise silently decide the relying
    # party for every call — which is the one thing decision 5 says must stay per-call.
    test "is not overruled by wax_'s own application environment" do
      put_env(:wax_, rp_id: "attacker.example", origin: "https://attacker.example")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)

      assert challenge.rp_id == @rp_id
      assert challenge.origin == @origin
    end

    # Asking for an attestation this library will not check refuses every authenticator that
    # honours the request. `attestation:` is passed rather than left to a default for the same
    # reason as above: configured elsewhere, it disagrees with what the browser was asked for and
    # Wax answers `:invalid_attestation_conveyance_preference`.
    test "asks for no attestation, whatever the environment says" do
      put_env(:wax_, attestation: "direct")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      assert {:ok, _attrs} = verify(credential, challenge)
    end

    # The same class as the attestation: not passed, and `wax_`'s environment decides. A challenge
    # that trusts only `:basic` refuses every registration this library can produce, and one that
    # demands a verified user disagrees with what the browser was asked for.
    test "pins the attestation types it trusts and whether the user must be verified" do
      put_env(:wax_, trusted_attestation_types: [:basic], user_verification: "required")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      assert challenge.user_verification == "preferred"
      assert {:ok, _attrs} = verify(credential, challenge)
    end

    # Wax compares it as a string, so an atom would leave the browser enforcing what the server does
    # not.
    test "refuses a user-verification setting Wax would not recognise" do
      assert_raise ArgumentError, ~r/user_verification: must be one of/, fn ->
        Passkeys.registration_challenge(@rp_id, @origin, user_verification: :required)
      end
    end
  end

  describe "registration_options/3" do
    setup do
      %{challenge: Passkeys.registration_challenge(@rp_id, @origin)}
    end

    test "names the relying party and the account for the browser", %{challenge: challenge} do
      user = user_fixture(%{email: "someone@example.test"})

      options = Passkeys.registration_options(challenge, user, rp_name: @rp_name)

      assert options.rp == %{id: @rp_id, name: @rp_name}
      assert options.user.name == "someone@example.test"
      assert options.user.displayName == "someone@example.test"
      assert options.challenge == Base.url_encode64(challenge.bytes, padding: false)
    end

    test "takes a bare identifier for an account that does not exist yet", %{challenge: challenge} do
      options =
        Passkeys.registration_options(challenge, "invited@example.test", rp_name: @rp_name)

      assert options.user.name == "invited@example.test"
      # Not the identifier itself: WebAuthn says a user handle must not identify a person.
      refute Base.url_decode64!(options.user.id, padding: false) =~ "invited@example.test"
    end

    test "and hands the same handle out on a second attempt", %{challenge: challenge} do
      first = Passkeys.registration_options(challenge, "invited@example.test", rp_name: @rp_name)
      second = Passkeys.registration_options(challenge, "invited@example.test", rp_name: @rp_name)

      assert first.user.id == second.user.id
    end

    test "refuses an account of a schema this library was not told about", ctx do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Passkeys.registration_options(ctx.challenge, %NamedUser{}, rp_name: @rp_name)
      end
    end

    test "insists on a discoverable credential, in both spellings", %{challenge: challenge} do
      options =
        Passkeys.registration_options(challenge, "someone@example.test", rp_name: @rp_name)

      assert options.authenticatorSelection.residentKey == "required"
      assert options.authenticatorSelection.requireResidentKey == true
      assert options.authenticatorSelection.userVerification == challenge.user_verification
      assert options.extensions == %{credProps: true}
      assert options.attestation == "none"
    end

    test "excludes the credentials the account already has", %{challenge: challenge} do
      user = user_fixture()
      one = key_fixture(user).key_id
      two = key_fixture(user).key_id
      stranger = key_fixture(user_fixture()).key_id

      options = Passkeys.registration_options(challenge, user, rp_name: @rp_name)

      listed = Enum.map(options.excludeCredentials, & &1.id)

      assert Enum.sort(listed) ==
               Enum.sort(Enum.map([one, two], &Base.url_encode64(&1, padding: false)))

      refute Base.url_encode64(stranger, padding: false) in listed
    end

    test "refuses to build options without a relying-party name", %{challenge: challenge} do
      assert_raise KeyError, fn ->
        Passkeys.registration_options(challenge, "someone@example.test", [])
      end
    end
  end

  describe "verify_registration/2" do
    setup do
      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      %{challenge: challenge, credential: credential}
    end

    test "answers the credential the authenticator attested", ctx do
      assert {:ok, attrs} = verify(ctx.credential, ctx.challenge)

      assert attrs.key_id == ctx.credential.key_id
      assert attrs.public_key == ctx.credential.public_key
    end

    test "turns away an authenticator that kept the credential to itself", ctx do
      assert {:error, :not_discoverable} =
               verify(ctx.credential, ctx.challenge, discoverable: false)
    end

    test "and the same answer when the browser said so as a string", ctx do
      assert {:error, :not_discoverable} =
               verify(ctx.credential, ctx.challenge, discoverable: "false")
    end

    test "but silence is not a denial", ctx do
      assert {:ok, _attrs} = verify(ctx.credential, ctx.challenge, discoverable: nil)
    end

    # `Wax` accepts authenticator data with no attested credential data — the registration simply
    # carries no credential. Reading a field off that would raise outside the rescue, which is a 500
    # with a stale challenge instead of the refusal every other bad registration gets.
    test "refuses a registration that carries no credential at all", ctx do
      assert {:error, :no_attested_credential} =
               verify(ctx.credential, ctx.challenge, attested: false)
    end

    test "refuses one where the person was not there", ctx do
      assert {:error, _reason} =
               verify(ctx.credential, ctx.challenge, flags: <<0b01000000>>)
    end

    # WebAuthn L2 §5.1.3 caps a credential id at 1023 bytes; `Wax` does not, and its length prefix
    # is 16 bits — so without this the size of a row in `ithibati_keys` is the browser's choice.
    test "refuses a credential id longer than the specification allows", ctx do
      oversized = %{ctx.credential | key_id: :crypto.strong_rand_bytes(1024)}

      assert {:error, :credential_id_too_long} = verify(oversized, ctx.challenge)
    end

    test "refuses an attestation for another challenge", ctx do
      other = Passkeys.registration_challenge(@rp_id, @origin)

      assert {:error, _reason} =
               Passkeys.verify_registration(
                 TestCredentials.attestation(ctx.credential, other),
                 ctx.challenge
               )
    end

    # Wax raises on some malformed input rather than answering. A caller of this library gets the
    # same error tuple either way, because the alternative is a 500 with a stale challenge behind it.
    test "answers rather than raising on rubbish", ctx do
      credential = TestCredentials.attestation(ctx.credential, ctx.challenge)
      broken = put_in(credential, ["response", "attestationObject"], "AQID")

      assert {:error, _reason} = Passkeys.verify_registration(broken, ctx.challenge)
    end

    # The body is the browser's like everything else it carries, so a shape this library never asked
    # for is refused rather than raised on.
    test "refuses a body that is not a credential at all", ctx do
      for nonsense <- [%{}, %{"response" => %{}}, "not a map", nil] do
        assert {:error, :malformed_credential} =
                 Passkeys.verify_registration(nonsense, ctx.challenge)
      end
    end

    # The extensions are the one member read by walking rather than matching, and a client may post
    # anything there — including shapes that make a walk raise instead of answer.
    test "and one whose extension results are any shape at all", ctx do
      credential = TestCredentials.attestation(ctx.credential, ctx.challenge)

      for extensions <- ["yes", 7, true, [], [1, 2], %{"credProps" => "x"}, %{"credProps" => []}] do
        assert {:ok, _attrs} =
                 Passkeys.verify_registration(
                   Map.put(credential, "clientExtensionResults", extensions),
                   ctx.challenge
                 )
      end
    end

    test "and one whose fields are not base64url", ctx do
      credential = TestCredentials.attestation(ctx.credential, ctx.challenge)
      broken = put_in(credential, ["response", "clientDataJSON"], "not base64url!!")

      assert {:error, :malformed_credential} = Passkeys.verify_registration(broken, ctx.challenge)
    end
  end

  describe "key_attrs/2" do
    test "keeps the name the browser sent" do
      attrs = Passkeys.key_attrs(%{key_id: <<1>>, public_key: <<2>>}, "Oliver's phone")

      assert attrs == %{key_id: <<1>>, public_key: <<2>>, label: "Oliver's phone"}
    end
  end

  defp verify(credential, challenge, opts \\ []) do
    Passkeys.verify_registration(
      TestCredentials.attestation(credential, challenge, opts),
      challenge
    )
  end
end
