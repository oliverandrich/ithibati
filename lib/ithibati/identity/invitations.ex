defmodule Ithibati.Identity.Invitations do
  @moduledoc """
  Opening an invitation, and accepting one.

  The invitation itself is the application's row — `Ithibati.Schema.Invitation` says why — so what
  is here is the half that would otherwise be written by hand and written slightly wrong: finding an
  invitation by the secret in a link, and marking it accepted in a way two people opening that link
  at once cannot both get through.

  Accepting composes into the caller's own transaction, beside the grant:

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, MyApp.Accounts.User.changeset(%User{}, account_attrs(invitation)))
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> Ithibati.Identity.Invitations.accept(invitation)
      |> Ecto.Multi.insert(:membership, fn %{account: account, invitation: invitation} -> … end)
      |> MyApp.Repo.transaction()
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Secrets
  alias Ithibati.Identity.Steps

  @doc """
  The pending invitation this token opens, or `nil`.

  Pending means not yet accepted and not past its expiry. One that is neither is answered the same
  way as a token nobody holds, deliberately.
  """
  def fetch(token) when is_binary(token) do
    Config.repo().one(
      from i in Config.invitation_schema!(),
        where: i.token_hash == ^Secrets.digest(token),
        where: is_nil(i.accepted_at),
        where: i.expires_at > ^DateTime.utc_now()
    )
  end

  def fetch(_token), do: nil

  @doc """
  The attributes an account created from this invitation starts with.

  Just the identifier, under the name the schemas agreed on — so a consumer composing the acceptance
  does not have to reach into this library to learn what that name is.
  """
  def account_attrs(invitation) do
    field = addressed_by(invitation)

    %{field => Map.fetch!(invitation, field)}
  end

  # Read off the struct rather than from the configuration, the same way `claim/2` reads the primary
  # key: an invitation of some other module would otherwise be read with the configured schema's
  # field name, which is either a wrong answer or a confusing error.
  defp addressed_by(%module{}), do: module.__ithibati_invitation__(:identifier)

  @doc """
  Marks the invitation accepted, as a step named `:invitation` in the caller's transaction.

  The step answers `{:error, :invalid_invitation}` when the invitation was accepted or expired in
  the meantime, which rolls the whole transaction back — so the account, its passkey and its codes
  go with it.

  It also refuses, with `{:error, :identifier_mismatch}`, an account being created under a different
  identifier from the one the invitation was addressed to. `account:` names the step that account
  comes from and defaults to `:account`, the name every fragment in this library uses; a transaction
  with no such step is not checked, because there is nothing to check it against.
  """
  def accept(multi, invitation, opts \\ []) do
    Multi.run(multi, :invitation, fn repo, changes ->
      with :ok <- confirm_addressee(changes, opts, invitation), do: claim(repo, invitation)
    end)
  end

  # An acceptance form that lets the invitee correct their address is an ordinary thing to build, and
  # it is the one that turns an invitation addressed to one person into an account for another —
  # along with whatever the application's own step reads off the invitation. Whose address the
  # invitation carries is the whole of what `validate_unclaimed` is about, so the binding is checked
  # here rather than left as advice. Nothing to check when the transaction creates no account: an
  # application is allowed to compose this step on its own.
  defp confirm_addressee(changes, opts, invitation) do
    case Steps.account(changes, opts) do
      :error ->
        :ok

      {:ok, account} ->
        field = addressed_by(invitation)
        compare(Map.get(account, field), Map.fetch!(invitation, field))
    end
  end

  defp compare(same, same), do: :ok
  defp compare(_account, _invitation), do: {:error, :identifier_mismatch}

  @doc """
  Invitations that ran out without being accepted.

  Nothing here sweeps them: what schedules a job is the application's business, and `fetch/1`
  refuses an expired invitation anyway, so one left lying is inert. The *query* is this library's,
  though, which is why both halves are offered — this one for a sweeper that wants to say what it is
  about to remove, `delete_expired/0` for one that does not.
  """
  def expired do
    Config.repo().all(expired_query())
  end

  @doc "Removes them, in one statement, and answers how many."
  def delete_expired do
    {count, _} = Config.repo().delete_all(expired_query())

    count
  end

  # "Unaccepted" rides the `WHERE` of the update that accepts it, and the row comes back from the
  # same statement — so two people opening one link cannot both get through. Both aim at the same
  # row, so the second waits on its lock and re-reads the committed version; `docs/design.md`
  # decision 8 sets out when that is enough and when it is not.
  defp claim(repo, invitation) do
    now = DateTime.utc_now()

    query =
      from(i in Config.invitation_schema!(),
        where: is_nil(i.accepted_at),
        where: i.expires_at > ^now,
        select: i
      )
      # Read off the struct rather than written out: the table is the application's, so what its
      # primary key is called is the application's to decide.
      |> where(^Ecto.primary_key!(invitation))

    repo.update_all(query, set: [accepted_at: now])
    |> Concurrency.one_affected(:invalid_invitation)
  end

  defp expired_query do
    from i in Config.invitation_schema!(),
      where: is_nil(i.accepted_at),
      where: i.expires_at <= ^DateTime.utc_now()
  end
end
