defmodule IthibatiInvitesWeb.InvitationEmailTest do
  use IthibatiInvitesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Ithibati.Identity.Invitations
  alias Ithibati.InvitationMail
  alias IthibatiInvites.Accounts.Invitation
  alias IthibatiInvites.Accounts.User
  alias IthibatiInvites.Registration
  alias IthibatiInvites.Repo
  alias IthibatiInvitesWeb.Auth

  setup do
    mail = Application.fetch_env!(:ithibati, :invitation_mail)
    open = Application.fetch_env!(:ithibati_invites, :open_registration)
    Application.put_env(:ithibati, :invitation_mail, Keyword.put(mail, :enabled, true))
    Application.put_env(:ithibati_invites, :open_registration, true)

    on_exit(fn ->
      Application.put_env(:ithibati, :invitation_mail, mail)
      Application.put_env(:ithibati_invites, :open_registration, open)
    end)

    {:ok, _} = Auth.register(session_conn(), key_attrs(), "admin", %{})
    :ok
  end

  test "an admin can send an existing link through the application mailer" do
    invitation = invite("ada")
    url = IthibatiInvitesWeb.Endpoint.url() <> "/invite/" <> invitation.token

    assert {:ok, _receipt} = InvitationMail.deliver("ada@example.test", url)

    assert_email_sent(fn email ->
      assert email.to == [{"", "ada@example.test"}]
      assert email.from == {"Ithibati invitations", "invites@example.test"}
      assert email.subject == "Your invitation"
      assert email.text_body =~ url
      assert email.html_body =~ url
    end)

    assert Invitations.fetch(invitation.token)
  end

  test "open registration mails a link and completes through existing invitation acceptance", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#request-invitation")

    view
    |> form("#request-invitation", %{username: "  Ada  ", email: "ada@example.test"})
    |> render_submit()

    assert render(view) =~ "If registration is available for these details"
    refute Repo.get_by(User, username: "ada")

    assert_email_sent(fn email ->
      assert email.to == [{"", "ada@example.test"}]
      [_, token] = Regex.run(~r{/invite/([A-Za-z0-9_-]+)}, email.text_body)
      assert {:ok, "ada"} = Auth.registration_subject(session_conn(), %{"token" => token})

      assert {:error, :invitation_required} =
               Auth.registration_subject(session_conn(), %{"username" => "ada"})

      assert {:ok, _conn} = Auth.register(session_conn(), key_attrs(), "ada", %{"token" => token})
      assert Repo.get_by(User, username: "ada")
      assert Invitations.fetch(token) == nil
    end)
  end

  test "both switches are required, including for direct event calls", %{conn: conn} do
    for {open, mail} <- [{false, true}, {true, false}] do
      Application.put_env(:ithibati_invites, :open_registration, open)
      config = Application.fetch_env!(:ithibati, :invitation_mail)
      Application.put_env(:ithibati, :invitation_mail, Keyword.put(config, :enabled, mail))

      {:ok, view, _} = live(conn, "/")
      refute has_element?(view, "#request-invitation")
      render_submit(view, "request-invitation", %{username: "ada", email: "ada@example.test"})

      assert {:error, :registration_closed} =
               Registration.request_invitation("ada", "ada@example.test")

      refute Repo.get_by(Invitation, username: "ada")
      refute_email_sent()
    end
  end

  test "existing names and invalid input receive the same public response", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")

    for params <- [
          %{username: "admin", email: "admin@example.test"},
          %{username: "bad name", email: "ada@example.test"},
          %{username: "ada", email: "not-an-email"}
        ] do
      render_submit(view, "request-invitation", params)
      assert render(view) =~ "If registration is available for these details"
      refute_email_sent()
    end

    assert Repo.aggregate(Invitation, :count) == 0
  end

  test "failed delivery leaves the invitation pending and is reported to the caller" do
    config = Application.fetch_env!(:ithibati, :invitation_mail)

    Application.put_env(
      :ithibati,
      :invitation_mail,
      Keyword.put(config, :deliver, fn _, _ -> {:error, :unavailable} end)
    )

    assert {:error, {:delivery, :unavailable}} =
             Registration.request_invitation("ada", "ada@example.test")

    assert %{accepted_at: nil} = Repo.get_by!(Invitation, username: "ada")
  end

  test "a request inside a transaction creates and sends nothing" do
    assert {:ok, {:error, :transaction_in_progress}} =
             Repo.transaction(fn ->
               Registration.request_invitation("ada", "ada@example.test")
             end)

    assert Repo.aggregate(Invitation, :count) == 0
    refute_email_sent()
  end

  defp invite(username) do
    %Invitation{} |> Invitation.changeset(%{username: username}) |> Repo.insert!()
  end

  defp key_attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  defp session_conn, do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
end
