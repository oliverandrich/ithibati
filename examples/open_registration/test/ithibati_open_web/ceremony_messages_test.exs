defmodule IthibatiOpenWeb.CeremonyMessagesTest do
  @moduledoc """
  Every code this library can send reaches a sentence of this application's own.

  The library publishes its vocabulary, so a new word arrives as a red suite instead of as a raw
  atom on somebody's screen.

  Read out of the source, the way `Ithibati.WalkthroughTest` reads this same file, because
  `message/1` is private to the LiveView. The second test is the one that proves the page is
  wired to it at all.
  """
  use IthibatiOpenWeb.ConnCase

  import Phoenix.LiveViewTest

  @page File.read!("lib/ithibati_open_web/live/sign_in_live.ex")

  test "every code the library can send has a clause of this application's own" do
    answered =
      ~r/message\("([a-z_]+)"\)/
      |> Regex.scan(@page)
      |> Enum.map(fn [_, code] -> String.to_atom(code) end)
      |> MapSet.new()

    missing = MapSet.difference(MapSet.new(Ithibati.Ceremony.codes()), answered)

    assert MapSet.size(missing) == 0,
           "no sentence for #{inspect(Enum.sort(missing))}, so the page shows the code itself"
  end

  # The set that arrives is open, so the catch-all is not a bug. Driven through the page, which is
  # also what says the handler calls `message/1` at all.
  test "and a code it has never heard of still reaches the catch-all" do
    {:ok, view, _html} = live(build_conn(), ~p"/")

    html =
      view
      |> element("#passkey")
      |> render_hook("ithibati:failed", %{"error" => "http_502"})

    assert html =~ "Something went wrong: http_502"
  end
end
