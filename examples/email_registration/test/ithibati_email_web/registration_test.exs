defmodule IthibatiEmailWeb.RegistrationTest do
  use IthibatiEmailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Ithibati.Identity.Invitations
  alias IthibatiEmail.Accounts.Invitation
  alias IthibatiEmail.Accounts.User
  alias IthibatiEmail.Registration
  alias IthibatiEmail.Repo
  alias IthibatiEmailWeb.Auth

  test "one email field requests a link without creating an account", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#request-invitation input[name=email]")
    refute has_element?(view, "input[name=username]")
    refute has_element?(view, "input[name=recipient]")

    view
    |> form("#request-invitation", %{email: "ADA@EXAMPLE.TEST"})
    |> render_submit()

    assert render(view) =~ "If registration is available for this email"
    assert Repo.aggregate(User, :count) == 0
    invitation = Repo.one!(Invitation)
    assert Map.fetch!(invitation, :email) == "ada@example.test"
    assert_email_sent(to: "ada@example.test")
  end

  test "normalized email is both identifier and recipient" do
    assert {:ok, _} = Registration.request_invitation("  Ada@Example.Test  ")

    assert_email_sent(fn email ->
      assert email.to == [{"", "ada@example.test"}]
      assert email.subject == "Complete your registration"
      assert email.html_body =~ "/invite/"
      [_, token] = Regex.run(~r{/invite/([A-Za-z0-9_-]+)}, email.text_body)
      assert %{email: "ada@example.test"} = Invitations.fetch(token)

      assert {:ok, "ada@example.test"} =
               Auth.registration_subject(session_conn(), %{"token" => token})
    end)
  end

  test "even the first account requires a mailed invitation" do
    for params <- [%{}, %{"email" => "ada@example.test"}] do
      assert {:error, :invitation_required} = Auth.registration_subject(session_conn(), params)

      assert {:error, :invitation_unknown} =
               Auth.register(session_conn(), key_attrs(), "ada@example.test", params)
    end

    assert Repo.aggregate(User, :count) == 0
  end

  test "accepting a link creates the email account and spends the invitation atomically" do
    invitation = invite("ada@example.test")
    params = %{"token" => invitation.token, "email" => "attacker@example.test"}

    assert {:ok, "ada@example.test"} = Auth.registration_subject(session_conn(), params)
    assert {:ok, _} = Auth.register(session_conn(), key_attrs(), "ada@example.test", params)
    assert Repo.get_by(User, email: "ada@example.test")
    refute Repo.get_by(User, email: "attacker@example.test")
    assert Invitations.fetch(invitation.token) == nil

    assert {:error, :invitation_unknown} =
             Auth.register(session_conn(), key_attrs(), "ada@example.test", params)
  end

  test "substituting another invitation cannot replace the approved email" do
    alice = invite("alice@example.test")
    bob = invite("bob@example.test")

    assert {:ok, "alice@example.test"} =
             Auth.registration_subject(session_conn(), %{"token" => alice.token})

    assert {:error, :invitation_unknown} =
             Auth.register(session_conn(), key_attrs(), "alice@example.test", %{
               "token" => bob.token
             })

    assert Repo.aggregate(User, :count) == 0
    assert Invitations.fetch(alice.token)
    assert Invitations.fetch(bob.token)
  end

  test "expired and unknown links cannot start or complete registration" do
    expired = invite("ada@example.test", days: -1)

    for token <- [expired.token, "unknown"] do
      assert {:error, :invitation_unknown} =
               Auth.registration_subject(session_conn(), %{"token" => token})

      assert {:error, :invitation_unknown} =
               Auth.register(session_conn(), key_attrs(), "ada@example.test", %{"token" => token})
    end

    assert Repo.aggregate(User, :count) == 0
  end

  test "invalid input and existing accounts get the same public response", %{conn: conn} do
    %User{} |> User.changeset(%{email: "existing@example.test"}) |> Repo.insert!()
    {:ok, view, _} = live(conn, "/")

    for email <- ["existing@example.test", "invalid", nil, %{"bad" => "input"}] do
      render_submit(view, "request-invitation", %{"email" => email})
      assert render(view) =~ "If registration is available for this email"
      refute_email_sent()
    end

    assert Repo.aggregate(Invitation, :count) == 0
  end

  test "disabled mail cannot issue invitations or bypass the token requirement", %{conn: conn} do
    with_mail(enabled: false)
    {:ok, view, _} = live(conn, "/")
    refute has_element?(view, "#request-invitation")
    render_submit(view, "request-invitation", %{email: "ada@example.test"})
    assert {:error, :registration_closed} = Registration.request_invitation("ada@example.test")

    assert {:error, :invitation_required} =
             Auth.registration_subject(session_conn(), %{"email" => "ada@example.test"})

    assert Repo.aggregate(Invitation, :count) == 0
    refute_email_sent()
  end

  test "delivery errors leave a pending invitation without an account" do
    with_mail(deliver: fn _, _ -> {:error, :unavailable} end)

    assert {:error, {:delivery, :unavailable}} =
             Registration.request_invitation("ada@example.test")

    assert %{accepted_at: nil} = Repo.one!(Invitation)
    assert Repo.aggregate(User, :count) == 0
  end

  test "requests cannot send from inside a transaction" do
    assert {:ok, {:error, :transaction_in_progress}} =
             Repo.transaction(fn ->
               Registration.request_invitation("ada@example.test")
             end)

    assert Repo.aggregate(Invitation, :count) == 0
    refute_email_sent()
  end

  test "development mailbox is absent from the ordinary test router", %{conn: conn} do
    assert get(conn, "/dev/mailbox").status == 404
  end

  defp with_mail(opts) do
    previous = Application.fetch_env!(:ithibati, :invitation_mail)
    Application.put_env(:ithibati, :invitation_mail, Keyword.merge(previous, opts))
    on_exit(fn -> Application.put_env(:ithibati, :invitation_mail, previous) end)
  end

  defp invite(email, opts \\ []) do
    %Invitation{} |> Invitation.changeset(%{email: email}, opts) |> Repo.insert!()
  end

  defp key_attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  defp session_conn, do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
end
