defmodule IthibatiInvitesWeb.CeremonyMessagesTest do
  @moduledoc """
  Every code this library can send reaches a sentence of this application's own.

  The library publishes its vocabulary, so a new word arrives as a red suite instead of as a raw
  atom on somebody's screen. Two of the clauses this guards are ones this application produces and
  could not explain until now: `already_claimed` and `identifier_mismatch`.
  """
  use IthibatiInvitesWeb.ConnCase

  import Phoenix.LiveViewTest

  alias IthibatiInvitesWeb.CeremonyMessages

  test "every code the library can send has a sentence of this application's own" do
    for code <- Ithibati.Ceremony.codes() do
      refute CeremonyMessages.message(to_string(code), nil) =~ "Something went wrong",
             "#{code} falls to the catch-all, so the page would show the code itself"
    end
  end

  test "and the two this application produces itself" do
    refute CeremonyMessages.message("already_claimed", nil) =~ "Something went wrong"
    refute CeremonyMessages.message("identifier_mismatch", nil) =~ "Something went wrong"
  end

  # The set that arrives is open, so the catch-all is not a bug.
  test "while a code nobody listed still says something" do
    assert CeremonyMessages.message("http_502", nil) == "Something went wrong: http_502"
  end

  # Driven through the page, because the clause above is worth nothing until something calls it
  # with two arguments. This example had the clause and both pages still called it with one.
  test "and the page hands on the name the browser gave" do
    {:ok, view, _html} = live(build_conn(), ~p"/")

    html =
      view
      |> element("#passkey")
      |> render_hook("ithibati:failed", %{
        "error" => "ceremony_failed",
        "exception" => "SecurityError"
      })

    assert html =~ "Your browser refused: SecurityError."
  end
end
