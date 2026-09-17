defmodule Ithibati.Identity.Grant do
  @moduledoc """
  Adds an account's first passkey and recovery codes to an application's `Ecto.Multi`.

  Create the account and any related application rows in the same transaction. Append the grant
  after steps that can refuse registration:

      alias Ecto.Multi
      alias MyApp.Accounts.User

      Multi.new()
      |> Multi.insert(:account, User.changeset(%User{}, attrs))
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  Use `Ithibati.Identity.Passkeys.add_key/2` to add a passkey to an existing account without
  replacing its recovery codes.
  """

  alias Ecto.Multi
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.Identity.Steps

  @doc """
  Returns the multi with `:passkey` and `:recovery_codes` steps appended.

  `key_attrs` must be verified credential attributes from
  `Ithibati.Identity.Passkeys.verify_registration/2`, optionally labelled with
  `Ithibati.Identity.Passkeys.key_attrs/2`. The multi must already contain the account step.

  ## Options

    * `:account` — name of the step that provides the account; defaults to `:account`.
    * `:count` — number of recovery codes; defaults to `12`. Accepts a non-negative integer.
      `0` issues no codes; invalid values raise when the step runs.

  Reserve `:passkey` and `:recovery_codes` for these steps. On transaction success,
  `:recovery_codes` contains the plaintext list to display. Existing codes for the account,
  if any, are replaced.

  > #### Keep plaintext codes out of failed transaction logs {: .warning}
  >
  > A later failure returns earlier step results in `changes_so_far`, including any plaintext
  > recovery codes already generated. Put bootstrap claims, invitation acceptance and other
  > steps that can refuse before this grant. Do not log complete transaction results.
  """
  def with_key_and_codes(multi, key_attrs, opts \\ []) do
    multi
    |> Multi.insert(:passkey, fn changes ->
      Passkeys.credential_changeset(key_attrs, Steps.account!(changes, opts))
    end)
    # Use the transaction's repo module so code issuance follows the multi's executor.
    # Ecto resolves dynamic-repo selection per process; this argument does not pin a connection.
    # The suite currently covers only the configured TestRepo, not dynamic-repo switching.
    |> Multi.run(:recovery_codes, fn repo, changes ->
      {:ok, RecoveryCodes.issue!(repo, Steps.account!(changes, opts), opts)}
    end)
  end
end
