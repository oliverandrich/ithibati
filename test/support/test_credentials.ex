defmodule Ithibati.TestCredentials do
  @moduledoc """
  A real credential, and what a browser would post back with it.

  Deliberately not a stand-in: a signature check that passes against a made-up key proves only that
  nobody looked. The pair here is a genuine ES256 one over P-256, the attestation object is CBOR
  shaped the way an authenticator sends it, and — in the authentication half — the assertion is
  signed over the bytes the specification names.

  `CBOR` and `Jason` are not dependencies of this library and are not declared as such — they arrive
  through `wax_`, which needs both at runtime. Declaring them would put two packages this library
  never calls into every consumer's dependency list; using them here is a test-estate liberty, and
  if `wax_` ever drops one this module is where it says so.
  """

  @doc """
  An ES256 credential, in the three shapes the ceremony needs it in: the COSE map as `Wax` hands it
  back, the same map term-encoded the way this library stores it, and the private scalar to sign
  with.
  """
  def credential do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public

    # COSE_Key for ES256 over P-256: kty EC2, alg ES256, crv P-256, then the two coordinates.
    cose = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

    %{
      key_id: :crypto.strong_rand_bytes(16),
      private: private,
      cose: cose,
      public_key: :erlang.term_to_binary(cose)
    }
  end

  @doc """
  What a browser posts back after a registration ceremony — the two raw values
  `Ithibati.Passkeys.verify_registration/4` takes, before base64url encoding.

  Two options, for tests that need an authenticator which did something else: `:flags` overrides the
  flag byte, and `attested: false` sends authenticator data with no attested credential data in it —
  which is a registration carrying no credential at all, and which `Wax` accepts.
  """
  def attestation(credential, challenge, opts \\ []) do
    %{
      attestation_object:
        CBOR.encode(%{
          "fmt" => "none",
          "attStmt" => %{},
          "authData" => bytes(authenticator_data(credential, challenge, opts))
        }),
      client_data: client_data("webauthn.create", challenge)
    }
  end

  @doc "The client data a browser sends for a ceremony of this type against this challenge."
  def client_data(type, challenge) do
    Jason.encode!(%{
      type: type,
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      origin: challenge.origin
    })
  end

  # Attested credential data is present, the person was there and was verified. The bit order is
  # the specification's: extension data, attested credential data, reserved, backup state, backup
  # eligibility, user verified, reserved, user present.
  @default_flags <<0b01000101>>

  # The same byte without the attested-credential-data bit.
  @flags_without_attested <<0b00000101>>

  defp authenticator_data(credential, challenge, opts) do
    {default_flags, attested} =
      if Keyword.get(opts, :attested, true),
        do: {@default_flags, attested_credential_data(credential)},
        else: {@flags_without_attested, <<>>}

    :crypto.hash(:sha256, challenge.rp_id) <>
      Keyword.get(opts, :flags, default_flags) <>
      <<0::unsigned-big-32>> <>
      attested
  end

  # An all-zero AAGUID is what an authenticator sends when it declines to identify its model, and it
  # is all this library ever wants: see decision 6.
  defp attested_credential_data(credential) do
    <<0::128>> <>
      <<byte_size(credential.key_id)::unsigned-big-16>> <>
      credential.key_id <>
      CBOR.encode(cbor_cose(credential.cose))
  end

  # `CBOR.encode/1` writes a bare Elixir binary as a text string; the coordinates are byte strings,
  # and `Wax` reads them back as binaries. Without the tag the key decodes to something that is not
  # a key.
  defp cbor_cose(cose) do
    Map.new(cose, fn
      {key, value} when is_binary(value) -> {key, bytes(value)}
      pair -> pair
    end)
  end

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}
end
