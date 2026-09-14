defmodule Ithibati.Doctor do
  @moduledoc """
  What an application has to get right before this library works, asked one question at a time.

  Everything here is already refused somewhere — by `Ithibati.Config` when a setting is read, by
  `Ithibati.Migration` when it builds, by Postgres when a ceremony writes. The trouble is *when*:
  each of those speaks at the first request that needed it, about the one thing that request
  touched, in the words of whichever layer noticed. An application can be wrong in three ways and
  hear about the first only.

  So this asks all of them at once, before anybody signs in, and answers about each. It changes
  nothing and writes nothing: every question is a read.

  The wording comes from the code that already refuses — `Config.repo/0` and its siblings raise
  sentences worth showing — rather than from a second set written here, which would drift from the
  first the day either was corrected.
  """

  alias Ecto.Adapters.SQL
  alias Ithibati.Catalogue
  alias Ithibati.Config
  alias Ithibati.Identity.Tokens

  # Named by the schemas that name them rather than restated here, so a suffix cannot drift from
  # the schema that declares it and a table added later cannot be silently unasked about.
  # `Ithibati.Migration` keeps its own list on purpose: that one is what version 1 created, and it
  # must not grow when this one does.
  @owned [Ithibati.Bootstrap, Ithibati.RecoveryCode, Ithibati.UserKey, Ithibati.UserToken]

  @doc """
  Every question, in order, as `{subject, {status, detail}}`.

  A status is `:ok`, `:error`, or `:skip` for a question that could not be asked — an application
  with no repo configured cannot be asked what is in its database, and saying so is a better
  answer than an exception from three layers down.

  `app` is the application being examined, and it is an argument rather than something read here
  because nothing in this library can derive it: `Mix.Project.config/0` knows, and Mix is not
  there in a release. Only the question about routes uses it.
  """
  def examine(app) do
    repo = answered(&Config.repo/0)
    answers = reachable(repo)
    database = askable(repo, answers)

    [
      {"config :ithibati, repo:", named(repo)},
      {"the repo answers", answers},
      {"config :ithibati, user_schema:", named(answered(&Config.user_schema/0))},
      {"config :ithibati, invitation_schema:", invitation_schema()},
      {"config :ithibati, token_validity:", validity()},
      {"this library's tables", with({:ok, it} <- database, do: tables(it))},
      {"config :ithibati, users_key_type:", with({:ok, it} <- database, do: account_key(it))},
      {"the identifier's unique index", with({:ok, it} <- database, do: identifier_index(it))},
      {"config :wax_", wax()},
      {"the ceremony routes", routes(app)}
    ]
  end

  # The two questions about the database are asked only of a repo that has already answered one.
  # Otherwise every one of them raises from inside Ecto, and because this list is built before a
  # line of it is printed, the reader would see nothing at all — not even the answer that
  # diagnosed it.
  defp askable(repo, {:ok, _}), do: repo
  defp askable(_repo, {:skip, _} = unasked), do: unasked
  defp askable(_repo, {:error, _}), do: {:skip, "the repo did not answer"}

  @doc """
  Whether a table's key column is the type this library was configured for, and carries the unique
  index a foreign key needs to point at it.

  Public because it is the one question here with an answer worth testing against a table made for
  the purpose; `examine/1` asks it about the account table.
  """
  def key_type(repo, prefix, table) do
    case Catalogue.table_oid(repo, prefix, table) do
      nil -> {:error, "there is no table #{Catalogue.qualified(prefix, table)}"}
      oid -> Catalogue.key_column(repo, oid, table, foreign_key(repo))
    end
  end

  defp account_key(repo) do
    case answered(&Config.user_schema/0) do
      {:error, _} -> {:skip, "no account schema to ask about"}
      {:ok, schema} -> key_type(repo, schema_prefix(repo), schema.__schema__(:source))
    end
  end

  # The migration creates this index, or confirms one the application said it maintains — but only
  # while it runs. Nothing asks afterwards, and an account lookup is `Repo.get_by/3`: without the
  # index two rows can share an identifier, and the second sign-in raises
  # `Ecto.MultipleResultsError` instead of letting somebody in.
  defp identifier_index(repo) do
    case answered(&Config.user_schema/0) do
      {:error, _} ->
        {:skip, "no account schema to ask about"}

      {:ok, schema} ->
        identifier_index(repo, schema.__schema__(:source), schema.__ithibati__(:identifier))
    end
  end

  defp identifier_index(repo, table, column) do
    prefix = schema_prefix(repo)

    with oid when not is_nil(oid) <- Catalogue.table_oid(repo, prefix, table),
         {_type, unique?} <- Catalogue.column(repo, oid, column) do
      if unique?,
        do: {:ok, "#{table}.#{column} carries one"},
        else:
          {:error,
           "#{table}.#{column} carries no unique index. An account is looked up by it with " <>
             "`Repo.get_by/3`, so two rows sharing one identifier raise " <>
             "`Ecto.MultipleResultsError` at the next sign-in rather than letting anybody in."}
    else
      _ -> {:error, "there is no #{Catalogue.qualified(prefix, table)}.#{column} to index"}
    end
  end

  defp tables(repo) do
    prefix = schema_prefix(repo)
    sources = Enum.map(@owned, & &1.__schema__(:source))

    case Enum.reject(sources, &Catalogue.table_oid(repo, prefix, &1)) do
      [] ->
        wildcard = Catalogue.qualified(prefix, "#{Config.table_prefix()}_*")
        {:ok, "all #{length(sources)} are there, as #{wildcard}"}

      missing ->
        {:error,
         "#{Enum.map_join(missing, ", ", &Catalogue.qualified(prefix, &1))} " <>
           "#{if length(missing) == 1, do: "is", else: "are"} missing — run this library's " <>
           "migration, or check `config :ithibati, table_prefix:` against what it created."}
    end
  end

  defp reachable({:error, _}), do: {:skip, "no repo to ask"}

  defp reachable({:ok, repo}) do
    SQL.query!(repo, "SELECT 1", [], log: false)
    {:ok, "yes"}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp invitation_schema do
    case answered(&Config.invitation_schema/0) do
      {:ok, nil} -> {:ok, "not configured, which is how an application without invitations looks"}
      other -> named(other)
    end
  end

  defp validity do
    with {:ok, _} <- answered(&Tokens.configured_validity!/0), do: {:ok, "readable"}
  end

  defp wax do
    case Enum.filter([:rp_id, :origin], &(Application.get_env(:wax_, &1) != nil)) do
      [] ->
        {:ok, "nothing set, which is right"}

      set ->
        {:error,
         "config :wax_, #{Enum.map_join(set, "/", &"#{&1}:")} is set and this library never " <>
           "reads it — the relying party and the origin are passed per call, so a non-browser " <>
           "client can present its own. Remove it, or know that it does nothing here."}
    end
  end

  # Keyed on the controller rather than on the sentinel every module of the web half is guarded
  # by, because this one cannot sit inside that guard — it has to compile and answer in a consumer
  # without Phoenix — and the controller is the module the routes have to dispatch to anyway.
  defp routes(app) do
    if Code.ensure_loaded?(Ithibati.Web.PasskeyController) do
      mounted(app)
    else
      {:skip, "the web half is not installed"}
    end
  end

  defp mounted(app) do
    case Enum.filter(application_modules(app), &mounts_ceremony?/1) do
      [] ->
        {:error,
         "no router calls `ithibati_routes/1`, so the four ceremony endpoints do not exist and " <>
           "the browser hook has nothing to post to."}

      routers ->
        {:ok, Enum.map_join(routers, ", ", &inspect/1)}
    end
  end

  defp mounts_ceremony?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__routes__, 0) and
      Enum.any?(module.__routes__(), &(&1.plug == Ithibati.Web.PasskeyController))
  end

  defp application_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  # The prefix a table lives under when nothing says otherwise — the same one `Ecto.Migration`
  # falls back to, so this asks about the tables the migration would have built.
  defp schema_prefix(repo), do: repo.config()[:migration_default_prefix]

  # `:migration_foreign_key` holds options, not a name — `Ecto.Migration.references/2` merges them
  # and takes `:column` from among them, defaulting to `:id`. Read as a bare name it is a keyword
  # list, which is not a column and does not survive being turned into one.
  defp foreign_key(repo) do
    Keyword.get(repo.config()[:migration_foreign_key] || [], :column, :id)
  end

  defp answered(fun) do
    {:ok, fun.()}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp named({:ok, value}), do: {:ok, inspect(value)}
  defp named(error), do: error
end
