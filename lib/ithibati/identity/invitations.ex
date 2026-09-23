defmodule Ithibati.Identity.Invitations do
  @moduledoc """
  Finds, lists and withdraws pending invitations, and composes their acceptance into
  application transactions.

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
  alias Ithibati.Identity.Mutations
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
  Returns the query that finds pending invitations, for the application to narrow.

  Pending means the same thing it means to `fetch/1`: unaccepted and unexpired. The application
  owns the table and whatever columns it added, so the list it wants is rarely all of them — it
  scopes, orders and preloads on top of this. Taking the predicate from here rather than writing
  it again is what keeps a page from offering a link that no longer opens anything, and keeps
  whatever the page can show to exactly what `withdraw/1` will take back.

  The query holds the moment it was built, not the moment it runs. Build it where you run it. A
  query kept across requests goes on listing invitations that have since expired, and each one
  offers a link that opens nothing. Ithibati asks no database for its own clock here, because
  the three it supports do not agree on what that answer means.
  """
  def pending_query do
    from i in Config.invitation_schema!(),
      where: is_nil(i.accepted_at),
      where: i.expires_at > ^DateTime.utc_now()
  end

  @doc "Returns every pending invitation. See `pending_query/0` to narrow the list first."
  def pending, do: Config.repo().all(pending_query())

  @doc """
  Takes back an invitation nobody has accepted, so its link opens nothing.

  Returns `{:ok, invitation}`, or `{:error, :already_accepted}` when the row was accepted or is
  no longer there. The state is rechecked inside the delete rather than read beforehand: an
  invitation accepted between the reading and the writing would otherwise be withdrawn along
  with the account it just made.

  An expired invitation can still be withdrawn. It opens nothing either way, and leaving the row
  for `delete_expired/0` is a separate decision.
  """
  def withdraw(%schema{} = invitation) do
    configured = Config.invitation_schema!()

    schema == configured ||
      raise ArgumentError,
            "expected a #{inspect(configured)}, got: #{inspect(schema)}"

    repo = Config.repo()

    query =
      from(i in configured, where: is_nil(i.accepted_at), select: i)
      # The application's invitation schema determines the primary-key fields.
      |> where(^Ecto.primary_key!(invitation))

    {:ok, outcome} =
      Concurrency.transaction(repo, fn ->
        case Mutations.delete_one(repo, query) do
          {1, [withdrawn]} -> {:ok, withdrawn}
          {0, _none} -> {:error, :already_accepted}
        end
      end)

    outcome
  end

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

    Mutations.update_one(repo, query, [set: [accepted_at: now]], :invalid_invitation)
  end

  defp expired_query do
    from i in Config.invitation_schema!(),
      where: is_nil(i.accepted_at),
      where: i.expires_at <= ^DateTime.utc_now()
  end
end
