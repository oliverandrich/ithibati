defmodule Ithibati.Identity.RecoveryCodesTest do
  @moduledoc """
  Issuing, spending and counting the second credential set. The race between two callers spending
  the same code is its own module, which needs a real connection each.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.RecoveryCode

  setup do
    %{user: user_fixture()}
  end

  describe "regenerate/1" do
    test "hands over a batch and writes down only digests", %{user: user} do
      codes = RecoveryCodes.regenerate(user)

      assert length(codes) == 12
      assert length(Enum.uniq(codes)) == 12

      stored =
        TestRepo.all(from r in RecoveryCode, where: r.user_id == ^user.id, select: r.code_hash)

      # First, because it is the claim: what the person was shown is not in the database.
      assert stored -- codes == stored
      assert Enum.sort(stored) == Enum.sort(Enum.map(codes, &:crypto.hash(:sha256, &1)))
    end

    # Read off paper and typed by somebody who has lost their phone: one case, one alphabet, no
    # separators to wonder about.
    test "in a form a person can type", %{user: user} do
      for code <- RecoveryCodes.regenerate(user) do
        assert code =~ ~r/\A[a-z2-7]{16}\z/
      end
    end

    test "and throws away what the account had before, spent or not", %{user: user} do
      [first | _] = old = RecoveryCodes.regenerate(user)
      {:ok, _, _} = RecoveryCodes.redeem(first)

      fresh = RecoveryCodes.regenerate(user)

      assert RecoveryCodes.remaining(user) == 12
      for code <- old, do: assert({:error, :invalid} = RecoveryCodes.redeem(code))
      assert {:ok, _, _} = RecoveryCodes.redeem(hd(fresh))
    end
  end

  describe "the application's two choices" do
    test "how many codes a batch holds", %{user: user} do
      assert length(RecoveryCodes.regenerate(user, count: 6)) == 6
      assert RecoveryCodes.remaining(user) == 6
    end

    # On by default, and the default is the whole argument of decision 8 — but an application that
    # would rather force a re-enrolment says so here.
    test "and whether the last one brings a fresh batch", %{user: user} do
      [only] = RecoveryCodes.regenerate(user, count: 1)

      assert {:ok, _account, nil} = RecoveryCodes.redeem(only, refill: false)
      assert RecoveryCodes.remaining(user) == 0
    end
  end

  describe "remaining/1" do
    test "counts what is left to spend", %{user: user} do
      assert RecoveryCodes.remaining(user) == 0

      [one, two | _] = RecoveryCodes.regenerate(user)
      assert RecoveryCodes.remaining(user) == 12

      {:ok, _, _} = RecoveryCodes.redeem(one)
      {:ok, _, _} = RecoveryCodes.redeem(two)

      assert RecoveryCodes.remaining(user) == 10
    end

    test "and does not count another account's", %{user: user} do
      RecoveryCodes.regenerate(user_fixture())

      assert RecoveryCodes.remaining(user) == 0
    end
  end

  describe "redeem/1" do
    setup %{user: user} do
      %{codes: RecoveryCodes.regenerate(user)}
    end

    test "answers the account that held the code", ctx do
      assert {:ok, account, nil} = RecoveryCodes.redeem(hd(ctx.codes))
      assert account.id == ctx.user.id
    end

    test "and spends it", ctx do
      code = hd(ctx.codes)

      assert {:ok, _, _} = RecoveryCodes.redeem(code)
      assert {:error, :invalid} = RecoveryCodes.redeem(code)
      assert RecoveryCodes.remaining(ctx.user) == 11
    end

    test "a code nobody holds is the same answer as one already spent", ctx do
      assert {:error, :invalid} = RecoveryCodes.redeem("nobodyholdsthis1")
      assert RecoveryCodes.remaining(ctx.user) == 12
    end

    # What a missing form field gives you, and answering it is kinder than crashing.
    test "and so is nothing at all", ctx do
      assert {:error, :invalid} = RecoveryCodes.redeem(nil)
      assert RecoveryCodes.remaining(ctx.user) == 12
    end

    # Anything else is a caller passing the wrong thing, and it should surface as that rather than
    # as somebody mistyping their code.
    test "but a caller passing the wrong thing hears about it" do
      for wrong <- [42, %{}, :code, ~c"charlist"] do
        assert_raise FunctionClauseError, fn -> RecoveryCodes.redeem(wrong) end
      end
    end

    # An account with no passkey and no codes left is locked out of a self-hosted instance for good,
    # and the moment to hand over the next batch is the one where somebody is looking at the screen.
    test "spending the last one brings a fresh batch with it", ctx do
      for code <- Enum.drop(ctx.codes, -1), do: {:ok, _, _} = RecoveryCodes.redeem(code)
      assert RecoveryCodes.remaining(ctx.user) == 1

      assert {:ok, _account, fresh} = RecoveryCodes.redeem(List.last(ctx.codes))

      assert length(fresh) == 12
      assert RecoveryCodes.remaining(ctx.user) == 12
      assert {:ok, _, _} = RecoveryCodes.redeem(hd(fresh))
    end

    test "and the batch it replaces is gone with it", ctx do
      [survivor | spent] = Enum.reverse(ctx.codes)
      for code <- spent, do: {:ok, _, _} = RecoveryCodes.redeem(code)

      {:ok, _account, fresh} = RecoveryCodes.redeem(survivor)

      refute Enum.any?(fresh, &(&1 in ctx.codes))

      assert TestRepo.aggregate(from(r in RecoveryCode, where: r.user_id == ^ctx.user.id), :count) ==
               12
    end
  end
end
