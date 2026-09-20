defmodule Ithibati.SetupCodeRaceTest do
  use Ithibati.RaceCase

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Identity.Instance
  alias Ithibati.SetupCode
  alias Ithibati.TestUser

  setup do
    previous = Application.fetch_env(:ithibati, :initial_claim)
    Application.put_env(:ithibati, :initial_claim, :operator_code)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ithibati, :initial_claim, value)
        :error -> Application.delete_env(:ithibati, :initial_claim)
      end
    end)
  end

  test "two holders of the same authorization cannot both claim" do
    {:ok, code} = Instance.issue_code()
    {:ok, proof} = Instance.authorize_code(code)
    results = racing_connections(2, fn -> claim(proof) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :bootstrap, :setup_authorization_required, _}, &1)
           ) == 1

    assert TestRepo.aggregate(TestUser, :count) == 1
    assert TestRepo.aggregate(Bootstrap, :count) == 1
    assert TestRepo.get(SetupCode, 1) == nil
  end

  test "rotation racing a claim never leaves a usable code for a claimed instance" do
    {:ok, code} = Instance.issue_code()
    {:ok, proof} = Instance.authorize_code(code)

    [issued, claimed] =
      racing([:issue, :claim], fn
        :issue -> Instance.issue_code()
        :claim -> claim(proof)
      end)

    case {issued, claimed} do
      {{:ok, replacement}, {:error, :bootstrap, :setup_authorization_required, _}} ->
        assert {:ok, _} = Instance.authorize_code(replacement)
        assert Instance.needs_setup?()

      {{:error, :already_claimed}, {:ok, _}} ->
        refute Instance.needs_setup?()
        assert TestRepo.get(SetupCode, 1) == nil
    end
  end

  defp claim(proof) do
    email = "racer-#{System.unique_integer([:positive])}@example.test"

    Multi.new()
    |> Multi.insert(:account, Ithibati.DataCase.user_changeset(%{email: email}))
    |> Instance.claim(authorization: proof)
    |> TestRepo.transaction()
  end

  defp clear do
    TestRepo.delete_all(Bootstrap)
    TestRepo.delete_all(SetupCode)
    TestRepo.delete_all(TestUser)
  end
end
