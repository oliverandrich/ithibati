defmodule Ithibati.Identity.Steps do
  @moduledoc false

  # Where this library's `Ecto.Multi` fragments find the account, in one place because it is one
  # convention: each of them reads it from a step the caller already ran, takes that step's name as
  # `account:`, and falls back to `:account`. Three public functions promise that default in their
  # docs — `Grant.with_key_and_codes/3`, `Invitations.accept/3` and `Instance.claim/2` — and a
  # default written out once per fragment is a default that drifts.

  alias Ithibati.Config

  @default :account

  def name(opts), do: Keyword.get(opts, :account, @default)

  # Named rather than left to `Map.fetch!`'s own message, which reports a missing key against a map
  # of every step run so far — a wall of changesets in which the actual mistake, a step named
  # something else, is the one thing not shown. Which fragment asked is in the stack trace and is
  # deliberately not repeated here, where nothing would keep it true through a rename.
  def account!(changes, opts) do
    step = name(opts)

    case changes do
      %{^step => account} ->
        Config.account!(account)

      _otherwise ->
        raise ArgumentError,
              "no step named #{inspect(step)} in this multi — this library's fragments read the " <>
                "account from the step that created it, and take its name as `account:`. " <>
                "Steps so far: #{inspect(Map.keys(changes))}"
    end
  end

  # For the one fragment that is allowed to run without an account: `Invitations.accept/3` composed
  # on its own has nothing to check an invitation's addressee against, and that is a shape an
  # application may want. A step that *is* there still has to hold an account.
  def account(changes, opts) do
    case Map.fetch(changes, name(opts)) do
      {:ok, account} -> {:ok, Config.account!(account)}
      :error -> :error
    end
  end
end
