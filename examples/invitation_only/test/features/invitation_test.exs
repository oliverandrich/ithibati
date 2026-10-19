defmodule IthibatiInvitesWeb.InvitationTest do
  @moduledoc """
  The flow this example exists to show, in a browser.

  Every test here is about a row an instance can hold exactly once — the claim, an invitation that
  is spent by being accepted. Nothing has to clean up between them: the browser shares the test's
  sandboxed connection, so each starts from an empty database and rolls back when it ends.
  """
  use IthibatiInvitesWeb.PlaywrightCase

  alias Ithibati.Identity.Instance
  alias IthibatiInvites.Accounts.Invitation

  # The two preludes the first test walks through with its own assertions, so that the tests about
  # something else can reach their subject in a line.
  defp enter_operator_code(conn) do
    {:ok, code} = Instance.issue_code()

    conn
    |> open("/")
    |> fill_in("Operator code", with: code)
    |> click_button("Continue to first account")
    |> connected()
  end

  defp claim(conn, username) do
    conn
    |> enter_operator_code()
    |> fill_in("Username", with: username)
    |> click_button("Claim this instance")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")
  end

  # The link is shown once and never again — the row holds the token's digest — so it is read here
  # or not at all.
  defp invite_link(conn, username) do
    conn
    |> open("/inside")
    |> fill_in("Their username", with: username)
    |> click_button("Create a link")
    |> assert_has("code")
    |> value_of("() => document.querySelector('code').textContent.trim()")
  end

  defp main_text(conn) do
    conn |> assert_has("main") |> value_of("() => document.querySelector('main').innerText")
  end

  test "the first account claims the instance, and everyone after it arrives on a link", %{
    conn: conn
  } do
    virtual_authenticator(conn)

    {:ok, code} = Instance.issue_code()

    conn
    |> open("/")
    |> assert_has("p", text: "Nobody has claimed this instance yet")
    |> refute_has("input[name=username]")
    |> fill_in("Operator code", with: code)
    |> click_button("Continue to first account")
    |> connected()
    |> fill_in("Username", with: "ada")
    |> click_button("Claim this instance")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")

    link = invite_link(conn, "grace")
    assert link =~ "/invite/"

    # A fresh session, because an invitation is for somebody who is not signed in.
    # It is checked here, not later: accepting signs the invitee in either way.
    # An assertion further down would hold whether or not this line did anything.
    conn
    |> clear_cookies()
    |> open("/")
    |> refute_has(".alert-success", text: "Signed in as")

    conn
    |> open(link)
    # The page names the account it will create and offers no field to change it — the refusal
    # `Invitations.accept/2` would give is turned into an interface that cannot ask for it.
    |> assert_has("p", text: "The account will be called")
    |> refute_has("main input")
    |> click_button("Accept with a passkey")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")

    conn
    |> open("/inside")
    |> assert_has("p", text: "Signed in as grace.")

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end

  # A used link, an expired one and one nobody ever held are one answer on purpose: anything else
  # tells a guesser which of their guesses was once real.
  test "a spent link and an invented one are answered exactly alike", %{conn: conn} do
    virtual_authenticator(conn)

    claim(conn, "ada")
    link = invite_link(conn, "grace")

    conn
    |> clear_cookies()
    |> open(link)
    |> click_button("Accept with a passkey")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")

    spent = conn |> clear_cookies() |> open(link) |> main_text()
    invented = conn |> open("/invite/a-token-nobody-ever-held") |> main_text()

    # Word for word, because anything else is a signal.
    assert spent == invented
    assert spent =~ "has been used already, or it has expired"
  end

  test "the instance can be claimed once, and the form does not come back", %{conn: conn} do
    virtual_authenticator(conn)

    claim(conn, "ada")

    conn
    |> open("/")
    |> assert_has("p", text: "Registration is by invitation")
    |> refute_has("main input")
  end
end
