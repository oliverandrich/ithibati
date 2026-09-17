defmodule Ithibati.Identity.Invitations do
  @moduledoc """
  Finds pending invitations and composes their acceptance into application transactions.

  The application owns the invitation schema and any membership or permission it grants.
  Ithibati checks the token, expiry and acceptance state, and binds the invitation's identifier
  to the account created in the transaction.

  For acceptance outside a WebAuthn ceremony:

      alias Ecto.Multi
      alias MyApp.Accounts.User

      Multi.new()
      |> Multi.insert(:account, User.changeset(%User{}, account_attrs(invitation)))
      |> Ithibati.Identity.Invitations.accept(invitation)
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  Insert application steps such as membership creation before the grant. In a WebAuthn handler,
  build the account from the subject approved at the challenge step, rather than rereading its
  identifier from the final request's invitation. See [Invitations](invitations.md).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Secrets
  alias Ithibati.Identity.Steps

  @doc """
  Returns the pending invitation for a plaintext token, or `nil`.

  Pending means unaccepted and unexpired. Unknown, accepted and expired tokens all return `nil`,
  as do non-string inputs. This lookup does not reserve the invitation; `accept/3` rechecks its
  state when writing.
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
  Returns a map containing the invitation's identifier under its declared field name.

  Use it to initialize an account outside a WebAuthn ceremony. During registration, use the
  subject supplied to `c:Ithibati.Web.Handler.register/4`, which was approved with the challenge.
  """
  def account_attrs(invitation) do
    field = addressed_by(invitation)

    %{field => Map.fetch!(invitation, field)}
  end

  # Read metadata from this invitation's schema, rather than assuming the configured module.
  defp addressed_by(%module{}), do: module.__ithibati_invitation__(:identifier)

  @doc """
  Appends an `:invitation` acceptance step and returns the multi.

  Pass an invitation struct, not `nil`; handle a failed `fetch/1` lookup before composing this
  step. The `:account` option names an earlier account step and defaults to `:account`.

  When the account step exists, acceptance checks that its identifier matches the invitation.
  A mismatch fails with `:identifier_mismatch`. If no account step exists, that comparison is
  skipped, allowing acceptance to be composed independently.

  The write rechecks expiry and acceptance state. If the invitation is no longer available,
  the step fails with `:invalid_invitation`. Concurrent attempts cannot both accept the same row.

  On success, `:invitation` contains the updated invitation. On failure, `Repo.transaction/1`
  returns `{:error, :invitation, reason, changes_so_far}` and rolls back the transaction. Place
  this step before `Ithibati.Identity.Grant.with_key_and_codes/3`.
  """
  def accept(multi, invitation, opts \\ []) do
    Multi.run(multi, :invitation, fn repo, changes ->
      with :ok <- confirm_addressee(changes, opts, invitation), do: claim(repo, invitation)
    end)
  end

  # Bind the invitation to the account step when present. Without this comparison, an
  # acceptance flow could create an account under a different identifier. Standalone acceptance
  # has no account to compare, but a present step must still contain a valid account.
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
  Returns expired invitations that have not been accepted.

  Ithibati schedules no cleanup. Use this list to inspect pending deletions, or call
  `delete_expired/0` to remove them. Expired invitations are refused by `fetch/1` regardless of
  whether their rows remain in the database.
  """
  def expired do
    Config.repo().all(expired_query())
  end

  @doc "Deletes expired, unaccepted invitations and returns the number of rows removed."
  def delete_expired do
    {count, _} = Config.repo().delete_all(expired_query())

    count
  end

  # Recheck state in the update itself so concurrent acceptances cannot both succeed.
  defp claim(repo, invitation) do
    now = DateTime.utc_now()

    query =
      from(i in Config.invitation_schema!(),
        where: is_nil(i.accepted_at),
        where: i.expires_at > ^now,
        select: i
      )
      # The application's invitation schema determines the primary-key fields.
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
