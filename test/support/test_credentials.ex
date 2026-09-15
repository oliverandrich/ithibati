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

  # Attested credential data is present, the person was there and was verified. The bit order is the
  # specification's: extension data, attested credential data, reserved, backup state, backup
  # eligibility, user verified, reserved, user present.
  @default_flags <<0b01000101>>

  # The same byte without the attested-credential-data bit.
  @flags_without_attested <<0b00000101>>

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
  What a browser posts after a registration ceremony: the `PublicKeyCredential` as `toJSON/0`
  serialises it, which is exactly what `Ithibati.Identity.Passkeys.verify_registration/2` takes.

  Options, for tests that need an authenticator or a client which did something else: `:flags`
  overrides the flag byte, `attested: false` sends authenticator data with no attested credential
  data in it — a registration carrying no credential at all, which `Wax` accepts — and
  `:discoverable` sets what the client reported under `credProps`, `nil` meaning it reported
  nothing. `:origin` picks which of a challenge's acceptable origins this browser was at.
  """
  def attestation(credential, challenge, opts \\ []) do
    object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => bytes(authenticator_data(credential, challenge, opts))
      })

    %{
      "id" => url64(credential.key_id),
      "type" => "public-key",
      "response" => %{
        "attestationObject" => url64(object),
        "clientDataJSON" => url64(client_data("webauthn.create", challenge, opts))
      },
      "clientExtensionResults" => extension_results(opts)
    }
  end

  defp extension_results(opts) do
    case Keyword.get(opts, :discoverable, true) do
      nil -> %{}
      reported -> %{"credProps" => %{"rk" => reported}}
    end
  end

  @doc """
  What a browser posts after an authentication ceremony: the `PublicKeyCredential` as `toJSON/0`
  serialises it, which is exactly what `Ithibati.Identity.Passkeys.verify_authentication/2` takes.

  The authenticator data is the same builder a registration uses with the attested credential data
  left out, which is what an assertion carries. `:flags` overrides the flag byte, for the test that
  asks what happens when the person was not there, and `:origin` picks which of a challenge's
  acceptable origins this browser was at.
  """
  def assertion(credential, challenge, opts \\ []) do
    client_data = client_data("webauthn.get", challenge, opts)
    auth_data = authenticator_data(credential, challenge, Keyword.put(opts, :attested, false))

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [credential.private, :secp256r1]
      )

    %{
      "id" => url64(credential.key_id),
      "type" => "public-key",
      "response" => %{
        "authenticatorData" => url64(auth_data),
        "clientDataJSON" => url64(client_data),
        "signature" => url64(signature)
      },
      "clientExtensionResults" => %{}
    }
  end

  @doc """
  The client data a browser would send, with `:origin` overridable.

  A challenge may name several acceptable origins — one extension has a different stable one in
  each browser — but a browser sends exactly the one it is running on, so a test of that has to be
  able to say which. Omitting it against such a challenge takes the first rather than emitting the
  list, which is a shape no browser sends and which would pass a test for the wrong reason.
  """
  def client_data(type, challenge, opts \\ []) do
    Jason.encode!(%{
      type: type,
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      origin: opts |> Keyword.get(:origin, challenge.origin) |> List.wrap() |> List.first()
    })
  end

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
  # is all this library ever wants.
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

  defp url64(value), do: Base.url_encode64(value, padding: false)
end
