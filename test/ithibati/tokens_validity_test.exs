defmodule Ithibati.Identity.TokensValidityTest do
  @moduledoc """
  How long a token lives, and what this library says when the setting that decides it is wrong.

  Not async: it moves the application environment `Ithibati.Identity.Tokens` reads. The happy paths that
  need no such move live in `Ithibati.IdentityTokenTest`.
  """
  use Ithibati.DataCase, async: false

  alias Ithibati.Identity.Tokens

  setup do
    configured = Application.fetch_env(:ithibati, :token_validity)

    on_exit(fn ->
      case configured do
        {:ok, value} -> Application.put_env(:ithibati, :token_validity, value)
        :error -> Application.delete_env(:ithibati, :token_validity)
      end
    end)

    %{user: user_fixture()}
  end

  test "session has a validity even when the application configures none", %{user: user} do
    Application.delete_env(:ithibati, :token_validity)

    token = Tokens.generate_session_token(user)

    assert Tokens.get_user_by_session_token(token)
    refute backdated(token, days(61)) |> Tokens.get_user_by_session_token()
  end

  # Merged rather than replaced: an application that adds a context for its extension must not have
  # to restate the one the session functions promise.
  test "a configured context is added to session, not swapped for it", %{user: user} do
    Application.put_env(:ithibati, :token_validity, %{"device" => {90, :day}})

    assert Tokens.generate_token(user, "device")
    assert Tokens.generate_session_token(user)
  end

  test "an application may override session too", %{user: user} do
    Application.put_env(:ithibati, :token_validity, %{"session" => {1, :second}})

    token = Tokens.generate_session_token(user)

    refute backdated(token, 5) |> Tokens.get_user_by_session_token()
  end

  describe "a setting this library will not run on" do
    # Each row: what the application wrote, and the phrase the refusal has to contain. The two
    # phrases are distinct on purpose — every error this raises would match a bare /token_validity/,
    # so a test asserting only that would pass on the wrong refusal.
    @rejected [
      {"a keyword list, the idiom every other setting here uses", [device: {90, :day}],
       ~r/expected a map keyed by context strings/},
      {"atom keys, which would otherwise merge and then read as unconfigured",
       %{device: {90, :day}}, ~r/expected a map keyed by context strings/},
      {"nil", nil, ~r/expected a map keyed by context strings/},
      {"a unit with no fixed length", %{"device" => {3, :month}},
       ~r/:month.*expected \{count, unit\}/s},
      {"a count of zero", %{"device" => {0, :day}}, ~r/expected \{count, unit\}/},
      {"something that is not a validity at all", %{"device" => 90}, ~r/expected \{count, unit\}/}
    ]

    for {name, value, pattern} <- @rejected do
      test name, %{user: user} do
        Application.put_env(:ithibati, :token_validity, unquote(Macro.escape(value)))

        assert_raise ArgumentError, unquote(Macro.escape(pattern)), fn ->
          Tokens.generate_session_token(user)
        end
      end
    end

    # The whole setting is checked, not only the entry being used — otherwise this boots, serves
    # every session request, and first raises inside the request carrying the first device token.
    test "a broken entry is refused even when another context is the one being used", %{
      user: user
    } do
      Application.put_env(:ithibati, :token_validity, %{"device" => {3, :month}})

      assert_raise ArgumentError, ~r/:month/, fn -> Tokens.generate_session_token(user) end
    end
  end

  test "a context nobody configured says which key would configure it", %{user: user} do
    assert_raise ArgumentError, ~r/no validity is configured for that context/, fn ->
      Tokens.generate_token(user, "no-such-context")
    end
  end

  defp days(n), do: n * 86_400

  defp backdated(token, seconds) do
    digest = :crypto.hash(:sha256, token)
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, _} =
      TestRepo.update_all(
        from(t in Ithibati.UserToken, where: t.token_hash == ^digest),
        set: [inserted_at: then]
      )

    token
  end
end
