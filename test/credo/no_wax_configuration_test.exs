defmodule Ithibati.Credo.NoWaxConfigurationTest do
  @moduledoc """
  The rule for the setting that looks like the place and is not.

  It reads config files, which Credo does not include by default — so the filename these are
  given is the one a consumer's `.credo.exs` has to reach for the rule to see anything.
  """
  use Credo.Test.Case, async: true

  alias Ithibati.Credo.NoWaxConfiguration

  defp check(source),
    do: source |> to_source_file("config/config.exs") |> run_check(NoWaxConfiguration)

  describe "it reports" do
    test "a relying party set where wax_ would read it" do
      """
      import Config

      config :wax_, rp_id: "example.test"
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "rp_id"
        assert issue.message =~ "passes it per call"
      end)
    end

    test "an origin, and both together as two findings rather than one" do
      """
      import Config

      config :wax_, origin: "https://example.test", rp_id: "example.test"
      """
      |> check()
      |> assert_issues(fn issues ->
        assert Enum.map(issues, & &1.trigger) |> Enum.sort() == ["origin", "rp_id"]
      end)
    end

    # `Application.get_all_env(:wax_)` picks this up exactly as it picks up the keyword form, so
    # a check that knew only one of them would bless the other.
    test "the three-argument form, which reaches wax_ just the same" do
      """
      import Config

      config :wax_, :rp_id, "example.test"
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "rp_id" end)
    end

    test "and the same written through Config.config/2" do
      """
      Config.config(:wax_, origin: "https://example.test")
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "origin" end)
    end
  end

  describe "it leaves alone" do
    # This writes `Application.get_env(:wax_, SomeModule)`, a key `wax_` never looks in — nothing
    # inert is being set, so a warning here would simply be wrong.
    test "a namespaced configuration under the same application" do
      """
      import Config

      config :wax_, SomeModule, rp_id: "example.test"
      """
      |> check()
      |> refute_issues()
    end

    # `wax_` has settings that do mean something; only the two this library overrides are inert.
    test "wax_ settings this library does not override" do
      """
      import Config

      config :wax_, allowed_attestation_types: [:basic, :none]
      """
      |> check()
      |> refute_issues()
    end

    test "the same keys under somebody else's application" do
      """
      import Config

      config :my_app, rp_id: "example.test", origin: "https://example.test"
      """
      |> check()
      |> refute_issues()
    end

    # A list built at run time has nothing recognisable in it, and a check that raised on one
    # would abort the whole Credo run rather than report anything.
    test "a configuration whose settings are computed" do
      """
      import Config

      config :wax_, Application.fetch_env!(:my_app, :wax)
      """
      |> check()
      |> refute_issues()
    end
  end
end
