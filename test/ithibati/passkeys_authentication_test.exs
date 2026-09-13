defmodule Ithibati.Identity.PasskeysAuthenticationTest do
  @moduledoc """
  The authentication half of the ceremony, driven with assertions this suite really signs.

  Not async: two of these move `wax_`'s own application environment, which every call into Wax
  reads.
  """
  use Ithibati.DataCase, async: false

  alias Ithibati.Identity.Passkeys
  alias Ithibati.UserKey

  @rp_id "localhost"
  @origin "http://localhost:4000"

  setup do
    user = user_fixture()
    credential = TestCredentials.credential()

    key =
      key_fixture(user, %{key_id: credential.key_id, public_key: credential.public_key})

    {:ok, challenge} = Passkeys.authentication_challenge(@rp_id, @origin)

    %{user: user, credential: credential, key: key, challenge: challenge}
  end

  describe "authentication_challenge/3" do
    test "carries the relying party it was given", ctx do
      assert ctx.challenge.rp_id == @rp_id
      assert ctx.challenge.origin == @origin
    end

    test "and refuses on an instance with no passkey at all" do
      TestRepo.delete_all(UserKey)

      assert {:error, :no_credentials} = Passkeys.authentication_challenge(@rp_id, @origin)
    end

    test "is not overruled by wax_'s own application environment", %{} do
      put_env(:wax_, rp_id: "attacker.example", origin: "https://attacker.example")

      assert {:ok, challenge} = Passkeys.authentication_challenge(@rp_id, @origin)
      assert challenge.rp_id == @rp_id
      assert challenge.origin == @origin
    end
  end

  describe "authentication_options/1" do
    # Naming them would turn a discoverable-credential sign-in into one restricted to the ids the
    # server already knows: the platform routes straight to whoever holds one and never offers a
    # chooser. And this runs unauthenticated by necessity, so every id it named would be readable by
    # anyone who opened the page.
    test "names no credential at all", ctx do
      options = Passkeys.authentication_options(ctx.challenge)

      assert options.allowCredentials == []
      assert options.rpId == @rp_id
      assert options.challenge == Base.url_encode64(ctx.challenge.bytes, padding: false)
      assert options.userVerification == ctx.challenge.user_verification
    end
  end

  describe "verify_authentication/2" do
    test "answers the account behind a real signature", ctx do
      assert {:ok, account} = authenticate(ctx)
      assert account.id == ctx.user.id
    end

    test "and moves the credential's last use", ctx do
      assert TestRepo.get!(UserKey, ctx.key.id).last_used_at == nil

      {:ok, _account} = authenticate(ctx)

      assert TestRepo.get!(UserKey, ctx.key.id).last_used_at
    end

    test "refuses a signature made for another challenge", ctx do
      {:ok, other} = Passkeys.authentication_challenge(@rp_id, @origin)

      assert {:error, _reason} =
               Passkeys.verify_authentication(
                 TestCredentials.assertion(ctx.credential, other),
                 ctx.challenge
               )

      assert TestRepo.get!(UserKey, ctx.key.id).last_used_at == nil
    end

    # The registered credential id, presented with a signature made by somebody else's key. Swapping
    # the whole credential would take the unknown-credential branch below instead and prove nothing
    # about the binding between an id and the key stored against it.
    test "refuses a signature made by a key registered to another account", ctx do
      stranger = TestCredentials.credential()

      credential =
        stranger
        |> TestCredentials.assertion(ctx.challenge)
        |> Map.put("id", Base.url_encode64(ctx.credential.key_id, padding: false))

      assert {:error, reason} = Passkeys.verify_authentication(credential, ctx.challenge)
      refute reason == :unknown_credential
    end

    # Anything the browser could not have got from this library is refused where it arrives, rather
    # than raising out of a query built from it.
    # Asserting the refusal alone would prove nothing: an id nothing registered is refused either
    # way. What only the guard can satisfy is that the database was never asked.
    test "refuses a credential id longer than one this library could have issued, without asking",
         ctx do
      credential =
        ctx.credential
        |> TestCredentials.assertion(ctx.challenge)
        |> Map.put("id", Base.url_encode64(:crypto.strong_rand_bytes(2048), padding: false))

      {result, queries} =
        counting_queries(fn -> Passkeys.verify_authentication(credential, ctx.challenge) end)

      assert result == {:error, :unknown_credential}
      assert queries == 0
    end

    # The body is the browser's like everything else it carries, so a shape this library never asked
    # for is refused rather than raised on.
    test "refuses a body that is not a credential at all", ctx do
      for nonsense <- [%{}, %{"response" => %{}}, "not a map", nil] do
        assert {:error, :malformed_credential} =
                 Passkeys.verify_authentication(nonsense, ctx.challenge)
      end
    end

    test "and one whose fields are not base64url", ctx do
      credential =
        ctx.credential
        |> TestCredentials.assertion(ctx.challenge)
        |> put_in(["response", "signature"], "not base64url!!")

      assert {:error, :malformed_credential} =
               Passkeys.verify_authentication(credential, ctx.challenge)
    end

    # Wax compares it as a string, so an atom would leave the browser enforcing what the server does
    # not.
    test "refuses a user-verification setting Wax would not recognise" do
      assert_raise ArgumentError, ~r/user_verification: must be one of/, fn ->
        Passkeys.authentication_challenge(@rp_id, @origin, user_verification: :required)
      end
    end

    # Distinguishable from a failed assertion: one means "no such passkey here", the other means
    # "that passkey did not sign this".
    test "and a credential nobody registered says so in its own words", ctx do
      credential =
        ctx.credential
        |> TestCredentials.assertion(ctx.challenge)
        |> Map.put("id", Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false))

      assert {:error, :unknown_credential} =
               Passkeys.verify_authentication(credential, ctx.challenge)
    end

    test "refuses when the stored key cannot be read at all", ctx do
      TestRepo.update_all(UserKey, set: [public_key: <<0, 1, 2>>])

      assert {:error, _reason} = authenticate(ctx)
    end

    test "refuses an assertion the person was not present for, whatever the environment says",
         ctx do
      put_env(:wax_, silent_authentication_enabled: true)

      {:ok, challenge} = Passkeys.authentication_challenge(@rp_id, @origin)

      assert {:error, _reason} =
               authenticate(%{ctx | challenge: challenge}, flags: <<0b00000100>>)
    end
  end

  defp counting_queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ithibati, :test_repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {ref, :query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach({__MODULE__, ref})

    {result, drain(ref, 0)}
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end

  defp authenticate(ctx, opts \\ []) do
    Passkeys.verify_authentication(
      TestCredentials.assertion(ctx.credential, ctx.challenge, opts),
      ctx.challenge
    )
  end
end
