if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.PasskeyControllerTest do
    @moduledoc """
    The property the challenge-deletion rule exists for: an assertion works once.

    Driven through the router rather than by calling the action, because the handler reaches the
    controller on the connection the router builds — calling the action directly would supply it by
    hand and prove nothing about the macro.
    """
    use Ithibati.DataCase, async: true

    import Phoenix.ConnTest

    alias Ithibati.Identity.RecoveryCodes
    alias Ithibati.TestCredentials

    @endpoint Ithibati.TestEndpoint

    # Through the endpoint, not the router: the session plug lives there, and a test that installed
    # a session by hand could not notice that the wiring a consumer copies never fetches one.
    # Cookies carry between requests the way a browser carries them.
    defp request(path, params, previous \\ nil) do
      conn = if previous, do: recycle(previous), else: build_conn()

      post(conn, path, params)
    end

    # The mount travels with the challenge, so reading it back means unwrapping that first. What
    # pins the separation is not this — it is the test that carries a challenge across mounts.
    defp challenge(conn, key) do
      {_settings, held} = Plug.Conn.get_session(conn, key)

      held
    end

    defp origins(mount) do
      mount
      |> Kernel.<>("/authentication/challenge")
      |> request(%{})
      |> challenge(:ithibati_authentication_challenge)
      |> Map.fetch!(:origin)
    end

    # Only the sign-in half needs one: `authentication_challenge/3` answers `:no_credentials` with
    # no key on file at all, and a registration builds its own credential inside the test.
    defp a_key_on_file(_ctx) do
      user = user_fixture()
      credential = TestCredentials.credential()
      key_fixture(user, %{key_id: credential.key_id, public_key: credential.public_key})

      %{user: user, credential: credential}
    end

    # Every test here drives the sign-in endpoints, which answer `:no_credentials` with
    # nothing on file at all. The registration tests build their own credential inside the
    # test and need none of it.
    describe "authentication" do
      setup :a_key_on_file

      test "an assertion signs in once and is refused the second time", ctx do
        started = request("/auth/authentication/challenge", %{})
        assert started.status == 200

        challenge = challenge(started, :ithibati_authentication_challenge)
        assert challenge, "the challenge has to survive between the two round-trips"

        assertion = TestCredentials.assertion(ctx.credential, challenge)

        signed_in = request("/auth/authentication", %{"credential" => assertion}, started)
        assert signed_in.status == 200
        assert signed_in.assigns.account.id == ctx.user.id

        replayed = request("/auth/authentication", %{"credential" => assertion}, signed_in)
        assert replayed.status == 422
        assert Jason.decode!(replayed.resp_body) == %{"error" => "no_challenge"}
      end

      # The path nobody writes a test for, because the successful one is the one on the mind. A
      # challenge left behind by a failure is a challenge an attacker may keep guessing against.
      test "a failed verification spends the challenge too" do
        started = request("/auth/authentication/challenge", %{})
        challenge = challenge(started, :ithibati_authentication_challenge)

        stranger = TestCredentials.assertion(TestCredentials.credential(), challenge)

        failed = request("/auth/authentication", %{"credential" => stranger}, started)
        assert failed.status == 422

        assert Plug.Conn.get_session(failed, :ithibati_authentication_challenge) == nil

        retried = request("/auth/authentication", %{"credential" => stranger}, failed)
        assert Jason.decode!(retried.resp_body) == %{"error" => "no_challenge"}
      end

      # The connection this node accepted is not what the browser saw: behind a proxy that terminates
      # TLS it says `http` and the wrong port, and every ceremony would fail on an origin mismatch in
      # production and nowhere else. The test conn's host is `www.example.com`; the endpoint is
      # configured as `https://example.test`, so only one of the two can be the answer.
      test "the relying party comes from the endpoint's configured URL, not from the connection" do
        started = request("/auth/authentication/challenge", %{})
        challenge = challenge(started, :ithibati_authentication_challenge)

        assert challenge.rp_id == "example.test"
        assert challenge.origin == "https://example.test"
      end

      # Two clients whose origin is not the server's own URL: a native app's
      # associated domain, and an extension's. They post to these same four routes, so the endpoint
      # derivation has to be a default rather than the only answer.
      test "a handler that says so decides the relying party, and may name several origins" do
        started = request("/extension/authentication/challenge", %{})
        held = challenge(started, :ithibati_authentication_challenge)

        # The id is deliberately the endpoint's host, because that is what it should be: an
        # extension names the server's domain rather than becoming its own relying party. So the
        # origins are what discriminate — and the endpoint's own is still among them, because the
        # same passkey has to keep working in the browser.
        assert held.rp_id == "example.test"
        assert "https://example.test" in held.origin
        assert Enum.any?(held.origin, &String.starts_with?(&1, "chrome-extension://"))
        assert Enum.any?(held.origin, &String.starts_with?(&1, "moz-extension://"))
      end

      # Every one of them, not whichever happens to be last: an implementation that honoured only
      # the head of the list would pass a test that picked one.
      test "an assertion made at any origin on that list verifies", ctx do
        for origin <- origins("/extension") do
          started = request("/extension/authentication/challenge", %{})
          held = challenge(started, :ithibati_authentication_challenge)

          assertion = TestCredentials.assertion(ctx.credential, held, origin: origin)
          signed_in = request("/extension/authentication", %{"credential" => assertion}, started)

          assert signed_in.status == 200, "an assertion made at #{origin} was refused"
        end
      end

      # Both of these were unreachable through the web half at first, and the handler's return value
      # looked like where to ask for them: an application that needed user verification would have
      # sent it, got no error, and been given "preferred" anyway — on both sides, since the browser's
      # options are read back off the challenge, so nothing would ever have looked wrong.
      test "the ceremony options a mount was given reach the challenge" do
        relaxed = request("/auth/authentication/challenge", %{})
        strict = request("/strict/authentication/challenge", %{})

        assert challenge(relaxed, :ithibati_authentication_challenge).user_verification ==
                 "preferred"

        assert challenge(strict, :ithibati_authentication_challenge).user_verification ==
                 "required"
      end

      # Two mounts may answer to different relying parties and different handlers. With one slot for
      # the whole application a challenge minted here could be verified there: the assertion validates
      # against its own challenge, so nothing refuses it, and the other mount's handler decides what
      # it is worth — a browser session where a scoped token was meant.
      test "a challenge minted at one mount cannot be spent at another", ctx do
        started = request("/extension/authentication/challenge", %{})
        held = challenge(started, :ithibati_authentication_challenge)

        assertion = TestCredentials.assertion(ctx.credential, held, origin: hd(held.origin))

        crossed = request("/auth/authentication", %{"credential" => assertion}, started)

        assert crossed.status == 422
        assert Jason.decode!(crossed.resp_body) == %{"error" => "no_challenge"}
      end

      # The authentication endpoint has no handler gate — it cannot, sign-in names nobody. So if both
      # ceremonies shared one session slot, a challenge taken from there would be accepted by the
      # registration endpoint, and `registration_subject` — the only place an instance can say "not
      # you" — would never be consulted. Wax does not save us: it checks the type the *client* put in
      # the client data, not the type of the challenge it is verifying against.
      test "a challenge minted for signing in cannot be spent on registering" do
        started = request("/auth/authentication/challenge", %{})
        assert started.status == 200

        challenge = challenge(started, :ithibati_authentication_challenge)
        attestation = TestCredentials.attestation(TestCredentials.credential(), challenge)

        smuggled = request("/auth/registration", %{"credential" => attestation}, started)

        assert smuggled.status == 422
        assert Jason.decode!(smuggled.resp_body) == %{"error" => "no_challenge"}
      end

      test "a body with no credential at all still spends the challenge" do
        started = request("/auth/authentication/challenge", %{})
        assert challenge(started, :ithibati_authentication_challenge)

        refused = request("/auth/authentication", %{}, started)
        assert refused.status == 422
        assert Plug.Conn.get_session(refused, :ithibati_authentication_challenge) == nil
      end
    end

    # A redeemed recovery code reaches the same place a verified assertion does: an account whose
    # holder has proved who they are, handed to the application to act on. The separate callback
    # exists because this one carries a third thing — the batch a spent last code produces, which
    # `authenticate/2` has nowhere to put and which nobody can be shown twice.
    describe "recovery" do
      test "a valid code signs the account in through the handler" do
        user = user_fixture()
        [code | _rest] = RecoveryCodes.regenerate(user)

        conn = request("/auth/recovery", %{"code" => code})

        assert conn.assigns.account.id == user.id
        assert conn.assigns.fresh == nil
        assert json_response(conn, 200)
      end

      test "spending the last code hands the fresh batch to the handler" do
        user = user_fixture()
        [code] = RecoveryCodes.regenerate(user, count: 1)

        conn = request("/auth/recovery", %{"code" => code})

        assert conn.assigns.account.id == user.id
        assert length(conn.assigns.fresh) == 12
      end

      test "a code that was already spent is refused, and says nothing about which" do
        user = user_fixture()
        [code | _rest] = RecoveryCodes.regenerate(user)
        request("/auth/recovery", %{"code" => code})

        conn = request("/auth/recovery", %{"code" => code})

        assert json_response(conn, 422) == %{"error" => "invalid_code"}
      end

      test "a code nobody holds is refused the same way" do
        conn = request("/auth/recovery", %{"code" => "not-a-code"})

        assert json_response(conn, 422) == %{"error" => "invalid_code"}
      end

      test "no code at all is refused without reaching the database" do
        conn = request("/auth/recovery", %{})

        assert json_response(conn, 422) == %{"error" => "invalid_code"}
      end

      # The code is spent by the time the handler answers, so a handler that answers the wrong
      # shape must not be reported as an invalid code: that sends somebody looking for a sheet of
      # paper which is now one line shorter. The other four actions let this mistake raise, and
      # `Ithibati.TestSloppyHandler` proves this one does too.
      test "a handler that answers recovered/3 with a bare conn raises rather than blaming the code" do
        code = List.first(RecoveryCodes.regenerate(user_fixture()))

        assert_raise WithClauseError, fn -> request("/sloppy/recovery", %{"code" => code}) end
      end
    end

    describe "registration" do
      test "the handler decides who may start one, and what the dialog is called" do
        started =
          request("/auth/registration/challenge", %{"identifier" => "someone@example.com"})

        assert started.status == 200
        assert challenge(started, :ithibati_registration_challenge)
        assert %{"rp" => %{"name" => "Ithibati Test"}} = Jason.decode!(started.resp_body)
      end

      test "a handler that refuses mints no challenge at all" do
        refused = request("/auth/registration/challenge", %{})

        assert refused.status == 422
        assert Jason.decode!(refused.resp_body) == %{"error" => "no_identifier"}
        assert Plug.Conn.get_session(refused, :ithibati_registration_challenge) == nil
      end

      test "a verified credential reaches the handler as the attributes a key is made of" do
        started =
          request("/auth/registration/challenge", %{"identifier" => "someone@example.com"})

        {challenge, _subject} = challenge(started, :ithibati_registration_challenge)

        attestation = TestCredentials.attestation(TestCredentials.credential(), challenge)

        registered =
          request("/auth/registration", %{"credential" => attestation}, started)

        assert registered.status == 200
        assert %{key_id: _, public_key: _} = registered.assigns.key_attrs
      end

      # The browser sends the whole body again at the verify step, so anything read from `params`
      # there is the client's word for it. An invitation-only instance would have approved one
      # identifier and enrolled a credential against whatever the second request claimed.
      test "the handler is told who was approved, not who the second request claims to be" do
        started =
          request("/auth/registration/challenge", %{"identifier" => "invited@example.com"})

        {challenge, _} = challenge(started, :ithibati_registration_challenge)
        attestation = TestCredentials.attestation(TestCredentials.credential(), challenge)

        registered =
          request(
            "/auth/registration",
            %{"credential" => attestation, "identifier" => "admin@example.com"},
            started
          )

        assert registered.status == 200
        assert registered.assigns.subject == "invited@example.com"
      end

      # The other half of the widened guard. Both challenge functions take the list, and only the
      # sign-in one was driven with one — a registration from an extension would have died on a
      # `FunctionClauseError` with nothing pointing at the origin.
      test "a registration works against a mount that names several origins" do
        started = request("/extension/registration/challenge", %{})
        {held, _subject} = challenge(started, :ithibati_registration_challenge)
        firefox = List.last(held.origin)

        attestation =
          TestCredentials.attestation(TestCredentials.credential(), held, origin: firefox)

        registered = request("/extension/registration", %{"credential" => attestation}, started)

        assert registered.status == 200
      end

      test "a replayed registration is refused" do
        started =
          request("/auth/registration/challenge", %{"identifier" => "someone@example.com"})

        {challenge, _subject} = challenge(started, :ithibati_registration_challenge)
        attestation = TestCredentials.attestation(TestCredentials.credential(), challenge)

        first = request("/auth/registration", %{"credential" => attestation}, started)
        assert first.status == 200

        replayed = request("/auth/registration", %{"credential" => attestation}, first)
        assert replayed.status == 422
        assert Jason.decode!(replayed.resp_body) == %{"error" => "no_challenge"}
      end
    end
  end
end
