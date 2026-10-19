defmodule IthibatiEmailWeb.RegistrationFeatureTest do
  use IthibatiEmailWeb.PlaywrightCase

  import Swoosh.TestAssertions

  alias IthibatiEmail.Accounts.Invitation

  setup :set_swoosh_global

  test "email request, mailed link, passkey, sign-out and sign-in", %{conn: conn} do
    authenticator = virtual_authenticator(conn)

    conn
    |> open("/")
    |> refute_has("input[name=username]")
    |> refute_has("button", text: "Claim this instance")
    |> fill_in("Email address", with: "ada@example.test")
    |> click_button("Email me a registration link")
    |> assert_has("#flash-info", text: "If registration is available for this email")

    assert Repo.aggregate(User, :count) == 0
    assert credentials(conn, authenticator) == []
    assert_receive {:email, email}
    assert email.to == [{"", "ada@example.test"}]
    [url] = Regex.run(~r{https?://[^\s]+/invite/[A-Za-z0-9_-]+}, email.text_body)

    conn
    |> open(url)
    |> assert_has("strong", text: "ada@example.test")
    |> click_button("Accept with a passkey")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")

    assert Repo.get_by(User, email: "ada@example.test")
    assert Repo.one!(Invitation).accepted_at

    conn
    |> open("/inside")
    |> assert_has("p", text: "Signed in as ada@example.test.")
    |> click_link("sign out")
    |> assert_path("/")
    |> connected()
    |> refute_has(".alert-success", text: "Signed in as")
    |> click_button("Sign in with a passkey")
    |> assert_has(".alert-success", text: "ada@example.test")

    conn
    |> clear_cookies()
    |> open(url)
    |> assert_has(".alert-error", text: "has been used already, or it has expired")
    |> refute_has("button", text: "Accept with a passkey")
  end
end
