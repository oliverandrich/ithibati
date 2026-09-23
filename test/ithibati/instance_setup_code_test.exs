defmodule Ithibati.Identity.InstanceSetupCodeTest do
  use Ithibati.DataCase, async: false

  alias Ecto.Multi
  alias Ithibati.Identity.Instance
  alias Ithibati.SetupCode

  setup do
    put_env(:ithibati, :initial_claim, :operator_code)
    :ok
  end

  test "a protected claim requires a current operator authorization" do
    assert {:ok, code} = Instance.issue_code()
    assert is_binary(code) and byte_size(code) >= 40
    assert %SetupCode{digest: digest} = TestRepo.get(SetupCode, 1)
    refute digest == code
    assert digest == :crypto.hash(:sha256, code)

    assert {:error, :bootstrap, :setup_authorization_required, _} = claim()
    assert Instance.needs_setup?()
    refute TestRepo.get_by(TestUser, email: "founder@example.test")

    assert {:error, :invalid_setup_code} = Instance.authorize_code("wrong")
    assert {:ok, proof} = Instance.authorize_code(code)
    assert Instance.authorized?(proof)
    assert {:ok, %{bootstrap: bootstrap}} = claim(proof)
    assert bootstrap.user_id
    refute Instance.needs_setup?()
    refute Instance.authorized?(proof)
    assert {:error, :already_claimed} = Instance.issue_code()
  end

  # An instance whose claim is open is a state a caller can be in, not a library used wrongly:
  # the application that asked for a code is configured one way and the library another, and
  # whoever typed the command or submitted the form deserves a sentence rather than a stack
  # trace. Raising also made this indistinguishable from a misconfigured repository, which
  # raises the same kind of error from the same call and means something else entirely.
  test "an open claim is answered, not raised" do
    put_env(:ithibati, :initial_claim, :open)

    assert {:error, :claim_is_open} = Instance.issue_code()
    assert {:error, :claim_is_open} = Instance.authorize_code("anything")
    assert {:error, :claim_is_open} = Instance.authorize_code(nil)
  end

  # A value nobody can read is the other thing: a mistake in the configuration rather than a
  # state, and one no answer can describe usefully.
  test "a claim mode that is not a mode still raises" do
    put_env(:ithibati, :initial_claim, :operator_codes)

    assert_raise ArgumentError, ~r/initial_claim/, &Instance.issue_code/0
    assert_raise ArgumentError, ~r/initial_claim/, fn -> Instance.authorize_code("anything") end
    assert_raise ArgumentError, ~r/initial_claim/, fn -> Instance.authorize_code(nil) end
  end

  test "rotation and expiry revoke authorization before the claim" do
    assert {:ok, first} = Instance.issue_code()
    assert {:ok, old_proof} = Instance.authorize_code(first)
    assert {:ok, second} = Instance.issue_code()
    refute Instance.authorized?(old_proof)
    assert {:error, :invalid_setup_code} = Instance.authorize_code(first)
    assert {:error, :bootstrap, :setup_authorization_required, _} = claim(old_proof)

    assert {:ok, proof} = Instance.authorize_code(second)
    refute Instance.authorized?(%{proof | expires_at: System.system_time(:second) - 1})
    assert {:ok, _} = claim(proof)
  end

  test "a failed account transaction does not spend the operator code" do
    assert {:ok, code} = Instance.issue_code()
    assert {:ok, proof} = Instance.authorize_code(code)

    assert {:error, :later, :refused, _} =
             Multi.new()
             |> Multi.insert(:account, user_changeset(%{email: "founder@example.test"}))
             |> Instance.claim(authorization: proof)
             |> Multi.error(:later, :refused)
             |> TestRepo.transaction()

    assert Instance.authorized?(proof)
    assert Instance.needs_setup?()
    assert {:ok, _} = claim(proof)
  end

  defp claim(proof \\ nil) do
    Multi.new()
    |> Multi.insert(:account, user_changeset(%{email: "founder@example.test"}))
    |> Instance.claim(authorization: proof)
    |> TestRepo.transaction()
  end
end
