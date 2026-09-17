if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.ChallengeRaceTest do
    use Ithibati.RaceCase
    import Phoenix.ConnTest
    import Ithibati.DataCase, only: [user_fixture: 0, key_fixture: 2]
    alias Ithibati.TestCredentials
    @endpoint Ithibati.TestEndpoint

    test "parallel requests using the same cookie reach authentication only once" do
      user = user_fixture()
      credential = TestCredentials.credential()
      key_fixture(user, %{key_id: credential.key_id, public_key: credential.public_key})
      started = post(build_conn(), "/auth/authentication/challenge", %{})
      {_settings, challenge} = Plug.Conn.get_session(started, :ithibati_authentication_challenge)
      assertion = TestCredentials.assertion(credential, challenge)

      results =
        racing_connections(4, fn ->
          post(recycle(started), "/auth/authentication", %{"credential" => assertion})
        end)

      assert Enum.count(results, &(&1.status == 200 and &1.assigns.account.id == user.id)) == 1

      assert Enum.count(results, &(&1.status == 422 and not Map.has_key?(&1.assigns, :account))) ==
               3
    end

    defp clear do
      TestRepo.delete_all(Ithibati.Challenge)
      TestRepo.delete_all(Ithibati.TestUser)
    end
  end
end
