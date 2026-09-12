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
      put_wax_env(rp_id: "attacker.example", origin: "https://attacker.example")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)

      assert challenge.rp_id == @rp_id
      assert challenge.origin == @origin
    end

    # Asking for an attestation this library will not check refuses every authenticator that
    # honours the request. `attestation:` is passed rather than left to a default for the same
    # reason as above: configured elsewhere, it disagrees with what the browser was asked for and
    # Wax answers `:invalid_attestation_conveyance_preference`.
    test "asks for no attestation, whatever the environment says" do
      put_wax_env(attestation: "direct")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      assert {:ok, _attrs} = verify(credential, challenge, true)
    end

    # The same class as the attestation: not passed, and `wax_`'s environment decides. A challenge
    # that trusts only `:basic` refuses every registration this library can produce, and one that
    # demands a verified user disagrees with what the browser was asked for.
    test "pins the attestation types it trusts and whether the user must be verified" do
      put_wax_env(trusted_attestation_types: [:basic], user_verification: "required")

      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      assert challenge.user_verification == "preferred"
      assert {:ok, _attrs} = verify(credential, challenge, true)
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

  describe "verify_registration/4" do
    setup do
      challenge = Passkeys.registration_challenge(@rp_id, @origin)
      credential = TestCredentials.credential()

      %{challenge: challenge, credential: credential}
    end

    test "answers the credential the authenticator attested", ctx do
      assert {:ok, attrs} = verify(ctx.credential, ctx.challenge, true)

      assert attrs.key_id == ctx.credential.key_id
      assert attrs.public_key == ctx.credential.public_key
    end

    test "turns away an authenticator that kept the credential to itself", ctx do
      assert {:error, :not_discoverable} = verify(ctx.credential, ctx.challenge, false)
    end

    test "and the same answer when the browser said so as a string", ctx do
      assert {:error, :not_discoverable} = verify(ctx.credential, ctx.challenge, "false")
    end

    test "but silence is not a denial", ctx do
      assert {:ok, _attrs} = verify(ctx.credential, ctx.challenge, nil)
    end

    # `Wax` accepts authenticator data with no attested credential data — the registration simply
    # carries no credential. Reading a field off that would raise outside the rescue, which is a 500
    # with a stale challenge instead of the refusal every other bad registration gets.
    test "refuses a registration that carries no credential at all", ctx do
      assert {:error, :no_attested_credential} =
               verify(ctx.credential, ctx.challenge, true, attested: false)
    end

    test "refuses one where the person was not there", ctx do
      assert {:error, _reason} =
               verify(ctx.credential, ctx.challenge, true, flags: <<0b01000000>>)
    end

    # WebAuthn L2 §5.1.3 caps a credential id at 1023 bytes; `Wax` does not, and its length prefix
    # is 16 bits — so without this the size of a row in `ithibati_keys` is the browser's choice.
    test "refuses a credential id longer than the specification allows", ctx do
      oversized = %{ctx.credential | key_id: :crypto.strong_rand_bytes(1024)}

      assert {:error, :credential_id_too_long} = verify(oversized, ctx.challenge, true)
    end

    test "refuses an attestation for another challenge", ctx do
      other = Passkeys.registration_challenge(@rp_id, @origin)

      %{attestation_object: object, client_data: client_data} =
        TestCredentials.attestation(ctx.credential, other)

      assert {:error, _reason} =
               Passkeys.verify_registration(object, client_data, ctx.challenge, true)
    end

    # Wax raises on some malformed input rather than answering. A caller of this library gets the
    # same error tuple either way, because the alternative is a 500 with a stale challenge behind it.
    test "answers rather than raising on rubbish", ctx do
      assert {:error, _reason} =
               Passkeys.verify_registration(<<1, 2, 3>>, "not json", ctx.challenge, true)
    end
  end

  describe "key_attrs/2" do
    test "keeps the name the browser sent" do
      attrs = Passkeys.key_attrs(%{key_id: <<1>>, public_key: <<2>>}, "Oliver's phone")

      assert attrs == %{key_id: <<1>>, public_key: <<2>>, label: "Oliver's phone"}
    end
  end

  defp verify(credential, challenge, discoverable, opts \\ []) do
    %{attestation_object: object, client_data: client_data} =
      TestCredentials.attestation(credential, challenge, opts)

    Passkeys.verify_registration(object, client_data, challenge, discoverable)
  end

  defp put_wax_env(pairs) do
    for {key, value} <- pairs do
      previous = Application.fetch_env(:wax_, key)
      Application.put_env(:wax_, key, value)
      on_exit(fn -> restore_wax_env(key, previous) end)
    end
  end

  defp restore_wax_env(key, {:ok, value}), do: Application.put_env(:wax_, key, value)
  defp restore_wax_env(key, :error), do: Application.delete_env(:wax_, key)
end
