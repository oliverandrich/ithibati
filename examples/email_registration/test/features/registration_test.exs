defmodule IthibatiEmailWeb.RegistrationFeatureTest do
  use IthibatiEmailWeb.FeatureCase

  import Swoosh.TestAssertions

  alias IthibatiEmail.Accounts.Invitation

  setup :set_swoosh_global

  feature "email request, mailed link, passkey, sign-out and sign-in", %{session: session} do
    authenticator = virtual_authenticator(session)

    session
    |> open("/")
    |> refute_has(css("input[name=username]"))
    |> refute_has(button("Claim this instance"))
    |> fill_in(css("input[name=email]"), with: "ada@example.test")
    |> click(button("Email me a registration link"))
    |> assert_has(css("#flash-info", text: "If registration is available for this email"))

    assert Repo.aggregate(User, :count) == 0
    assert credentials(session, authenticator) == []
    assert_receive {:email, email}
    assert email.to == [{"", "ada@example.test"}]
    [url] = Regex.run(~r{https?://[^\s]+/invite/[A-Za-z0-9_-]+}, email.text_body)

    session
    |> open(url)
    |> assert_has(css("strong", text: "ada@example.test"))
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Your recovery codes"))

    assert Repo.get_by(User, email: "ada@example.test")
    assert Repo.one!(Invitation).accepted_at

    session
    |> open("/inside")
    |> assert_has(css("p", text: "Signed in as ada@example.test."))
    |> click(link("sign out"))
    |> landed_on("/")
    |> connected()
    |> refute_has(css(".alert-success", text: "Signed in as"))
    |> click(button("Sign in with a passkey"))
    |> through_navigation(css(".alert-success", text: "ada@example.test"))

    session
    |> clear_cookies()
    |> open(url)
    |> assert_has(css(".alert-error", text: "has been used already, or it has expired"))
    |> refute_has(button("Accept with a passkey"))
  end
end
