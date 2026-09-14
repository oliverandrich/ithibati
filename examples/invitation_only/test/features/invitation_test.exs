defmodule IthibatiInvitesWeb.InvitationTest do
  @moduledoc """
  The flow this example exists to show, in a browser.

  Every test here is about a row an instance can hold exactly once — the claim, an invitation that
  is spent by being accepted. Nothing has to clean up between them: Wallaby shares the test's
  sandboxed connection, so each starts from an empty database and rolls back when it ends.
  """
  use IthibatiInvitesWeb.FeatureCase

  alias IthibatiInvites.Accounts.Invitation

  # The two preludes the first test walks through with its own assertions, so that the tests about
  # something else can reach their subject in a line.
  defp claim(session, username) do
    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: username)
    |> click(button("Claim this instance"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Your recovery codes"))
  end

  # The link is shown once and never again — the row holds the token's digest — so it is read here
  # or not at all.
  defp invite_link(session, username) do
    session
    |> open("/inside")
    |> fill_in(css("input[name=username]"), with: username)
    |> click(button("Create a link"))
    |> find(css("code"))
    |> Element.text()
    |> String.trim()
  end

  defp main_text(session), do: session |> find(css("main")) |> Element.text()

  feature "the first account claims the instance, and everyone after it arrives on a link", %{
    session: session
  } do
    virtual_authenticator(session)

    session
    |> open("/")
    |> assert_has(css("p", text: "Nobody has claimed this instance yet"))
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Claim this instance"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Your recovery codes"))

    link = invite_link(session, "grace")
    assert link =~ "/invite/"

    # A fresh session, because an invitation is for somebody who is not signed in — and checked
    # here rather than after the fact: accepting signs you in as the invitee either way, so an
    # assertion further down holds whether or not this line did anything.
    session
    |> clear_cookies()
    |> open("/")
    |> refute_has(css(".alert-success", text: "Signed in as"))

    session
    |> open(link)
    # The page names the account it will create and offers no field to change it — the refusal
    # `Invitations.accept/2` would give is turned into an interface that cannot ask for it.
    |> assert_has(css("p", text: "The account will be called"))
    |> refute_has(css("main input"))
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Your recovery codes"))

    session
    |> open("/inside")
    |> assert_has(css("p", text: "Signed in as grace."))

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end

  # A used link, an expired one and one nobody ever held are one answer on purpose: anything else
  # tells a guesser which of their guesses was once real.
  feature "a spent link and an invented one are answered exactly alike", %{session: session} do
    virtual_authenticator(session)

    claim(session, "ada")
    link = invite_link(session, "grace")

    session
    |> clear_cookies()
    |> open(link)
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Your recovery codes"))

    spent = session |> clear_cookies() |> open(link) |> main_text()
    invented = session |> open("/invite/a-token-nobody-ever-held") |> main_text()

    # Word for word, because anything else is a signal.
    assert spent == invented
    assert spent =~ "has been used already, or it has expired"
  end

  feature "the instance can be claimed once, and the form does not come back", %{session: session} do
    virtual_authenticator(session)

    claim(session, "ada")

    session
    |> open("/")
    |> assert_has(css("p", text: "Registration is by invitation"))
    |> refute_has(css("main input"))
  end
end
