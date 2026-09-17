defmodule Ithibati.Doctor do
  @moduledoc """
  Checks configuration, database state and web integration without changing them.

  `examine/1` checks the configured repo, database adapter, schemas, tables, indexes, session
  validity, ceremony routes and handler callbacks. Database and application processes must
  be available for the corresponding checks to run.

  The doctor reuses configuration validation and catalogue queries from the integration itself.
  `mix ithibati.doctor` starts the consuming application and prints these findings.
  See [Setup checks](doctor.md) for common failures and fixes.
  """

  alias Ecto.Adapters.SQL
  alias Ithibati.Catalogue
  alias Ithibati.Config
  alias Ithibati.Identity.Sessions
  # The alias remains valid when the optional web module is absent.
  alias Ithibati.Web.Handler

  # Read table names from their schemas. Migration keeps a separate, version-pinned list
  # that must not grow when a later release adds a table.
  @owned [Ithibati.Bootstrap, Ithibati.RecoveryCode, Ithibati.Session, Ithibati.UserKey]

  @doc """
  Returns an ordered list of `{subject, {status, detail}}` findings for the application.

  `app` is the consuming OTP application's name. It is used to discover web integration modules.
  Other checks read the configured repo and schemas.

  A status is `:ok`, `:error` or `:skip`. Checks whose prerequisites are unavailable are skipped;
  for example, an unreachable repo prevents database-table checks.

  This function neither starts the application nor changes its configuration or database.
  The Mix task starts the application before calling it.
  """
  def examine(app) do
    repo = answered(&Config.repo/0)
    adapter = adapter(repo)
    answers = reachable(repo, adapter)
    database = askable(repo, answers)

    [
      {"config :ithibati, repo:", named(repo)},
      {"the database adapter", adapter},
      {"the repo answers", answers},
      {"config :ithibati, user_schema:", named(answered(&Config.user_schema/0))},
      {"config :ithibati, invitation_schema:", invitation_schema()},
      {"config :ithibati, session_validity:", validity()},
      {"this library's tables", with({:ok, it} <- database, do: tables(it))},
      {"config :ithibati, users_key_type:", with({:ok, it} <- database, do: account_key(it))},
      {"the identifier's unique index", with({:ok, it} <- database, do: identifier_index(it))},
      {"the invitation table", with({:ok, it} <- database, do: invitation_table(it))},
      {"config :wax_", wax()},
      {"the ceremony routes", routes(app)},
      {"the handler's callbacks", callbacks(app)},
      {"the handler each mount names", reachable_handlers(app)}
    ]
  end

  # Skip database checks when the initial connection check fails, preserving the
  # original diagnostic instead of raising while building the report.
  defp askable(repo, {:ok, _}), do: repo
  defp askable(_repo, {:skip, _} = unasked), do: unasked
  defp askable(_repo, {:error, _}), do: {:skip, "the repo did not answer"}

  @doc """
  Checks whether a table's referenced account key matches Ithibati's foreign-key requirements.

  Returns `{:ok, description}` or `{:error, description}`. Checks the column type against
  `users_key_type` and requires a unique index on that column alone. The repo's
  `:migration_foreign_key` option chooses the column, defaulting to `:id`.

  `prefix` is a PostgreSQL schema prefix or `nil`. Queries the supplied repo without modifying it.
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

  # Recheck uniqueness after migration to detect missing indexes or configuration changes.
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
           "#{table}.#{column} carries no unique index. Two registrations of the same " <>
             "identifier at the same moment both pass the changeset and both insert, and the " <>
             "identifier then names two accounts."}
    else
      _ -> {:error, "there is no #{Catalogue.qualified(prefix, table)}.#{column} to index"}
    end
  end

  # Check invitation storage even when invitations were configured after the initial migration.
  defp invitation_table(repo) do
    case answered(&Config.invitation_schema/0) do
      {:ok, nil} -> {:skip, "no invitation schema to ask about"}
      # Not "none configured": `invitation_schema/0` raises when one *is* configured and its
      # identifier disagrees with the account schema's, which is the opposite of absent.
      {:error, _} -> {:skip, "the invitation schema did not answer"}
      {:ok, schema} -> invitation_table(repo, schema)
    end
  end

  defp invitation_table(repo, schema) do
    prefix = schema_prefix(repo)
    table = schema.__schema__(:source)

    case Catalogue.table_oid(repo, prefix, table) do
      nil ->
        {:error,
         "there is no table #{Catalogue.qualified(prefix, table)}, and " <>
           "`config :ithibati, invitation_schema:` names one."}

      oid ->
        invitation_columns(repo, prefix, table, oid)
    end
  end

  defp invitation_columns(repo, prefix, table, oid) do
    case Catalogue.column(repo, oid, :token_hash) do
      nil ->
        {:error, "#{Catalogue.qualified(prefix, table)} has no token_hash column."}

      {_type, false} ->
        {:error,
         "#{table}.token_hash carries no unique index. The token in an invitation link is a " <>
           "bearer secret, and it is looked up by that digest — this library's migration " <>
           "creates the index, so a table added after that migration ran needs " <>
           "`Ithibati.Migration.invitation_index/1` in one of your own."}

      {_type, true} ->
        {:ok, "#{table}.token_hash carries a unique index"}
    end
  end

  # Applications may compile despite missing-callback warnings. Report them before a request fails.
  defp callbacks(app) do
    if Code.ensure_loaded?(Handler) do
      implemented(app)
    else
      {:skip, "the web half is not installed"}
    end
  end

  defp implemented(app) do
    case Enum.filter(application_modules(app), &handler?/1) do
      [] -> {:skip, "no module implements Ithibati.Web.Handler"}
      handlers -> report_callbacks(handlers)
    end
  end

  # Keep a local callback list because Handler is absent without the optional dependencies.
  # DoctorTest checks this list against the behaviour when the web half is installed.
  @required [registration_subject: 2, register: 4, authenticate: 2, recovered: 3]

  @doc false
  def required_callbacks, do: @required

  # Read every behaviour attribute: Phoenix controllers also implement Plug, which may
  # be the first entry in the keyword list.
  defp handler?(module) do
    Code.ensure_loaded?(module) and Handler in behaviours(module)
  end

  defp behaviours(module) do
    for {:behaviour, declared} <- module.module_info(:attributes), behaviour <- declared do
      behaviour
    end
  end

  defp arities(missing),
    do: Enum.map_join(missing, " and ", fn {fun, arity} -> "#{fun}/#{arity}" end)

  @doc false
  def missing_callbacks(module) do
    {module,
     Enum.reject(required_callbacks(), fn {fun, arity} ->
       function_exported?(module, fun, arity)
     end)}
  end

  defp report_callbacks(handlers) do
    case Enum.reject(Enum.map(handlers, &missing_callbacks/1), &(elem(&1, 1) == [])) do
      [] ->
        {:ok,
         Enum.map_join(handlers, ", ", &inspect/1) <>
           " implement all #{length(required_callbacks())}"}

      incomplete ->
        {:error,
         Enum.map_join(incomplete, "; ", fn {module, missing} ->
           "#{inspect(module)} is missing " <> arities(missing)
         end) <>
           ". A ceremony that reaches one of these raises at the request; " <>
           "`Ithibati.Web.Handler` documents each callback and what it answers."}
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
           "#{if match?([_], missing), do: "is", else: "are"} missing — run this library's " <>
           "migration, or check `config :ithibati, table_prefix:` against what it created."}
    end
  end

  defp adapter({:error, _}), do: {:skip, "no repo to ask"}

  defp adapter({:ok, repo}) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres ->
        {:ok, "PostgreSQL"}

      other ->
        {:error, "Ithibati requires PostgreSQL; #{inspect(repo)} uses #{inspect(other)}."}
    end
  end

  defp reachable(_repo, {:skip, _} = skipped), do: skipped

  defp reachable(_repo, {:error, _}),
    do: {:skip, "the database adapter is not supported"}

  defp reachable({:ok, repo}, {:ok, _}) do
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
    with {:ok, _} <- answered(&Sessions.configured_validity!/0), do: {:ok, "readable"}
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

  # Doctor also runs without Phoenix, so inspect routes only when their controller is available.
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
         "no router calls `ithibati_routes/1`, so the ceremony endpoints do not exist and " <>
           "the browser hook has nothing to post to."}

      routers ->
        {:ok, Enum.map_join(routers, ", ", &inspect/1)}
    end
  end

  # Validate the handler actually named by each mount; see docs/doctor.md.
  defp reachable_handlers(app) do
    if Code.ensure_loaded?(Ithibati.Web.PasskeyController) do
      app |> application_modules() |> Enum.filter(&publishes_mounts?/1) |> judge_mounts()
    else
      {:skip, "the web half is not installed"}
    end
  end

  defp judge_mounts([]), do: {:skip, "no router calls `ithibati_routes/1`"}

  defp judge_mounts(routers) do
    handlers = routers |> Enum.flat_map(& &1.__ithibati_mounts__()) |> Enum.uniq()

    case Enum.reject(Enum.map(handlers, &{&1, mount_fault(&1)}), &(elem(&1, 1) == nil)) do
      [] -> {:ok, Enum.map_join(handlers, ", ", &inspect/1)}
      faults -> {:error, Enum.map_join(faults, "; ", &fault_sentence/1) <> "."}
    end
  end

  defp fault_sentence({handler, :not_loaded}) do
    "#{inspect(handler)} is mounted and is not loaded. A ceremony posted to that mount raises " <>
      "instead of answering, and nothing before this said so"
  end

  defp fault_sentence({handler, {:missing, missing}}),
    do: "#{inspect(handler)} is mounted and is missing " <> arities(missing)

  defp publishes_mounts?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ithibati_mounts__, 0)
  end

  @doc false
  # Load the module first so an unavailable handler is distinct from missing callbacks.
  def mount_fault(handler) do
    if Code.ensure_loaded?(handler) do
      case missing_callbacks(handler) do
        {_, []} -> nil
        {_, missing} -> {:missing, missing}
      end
    else
      :not_loaded
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

  # Use the same default prefix as Ecto.Migration.
  defp schema_prefix(repo), do: repo.config()[:migration_default_prefix]

  # Read the target column from the same options Ecto.Migration.references/2 uses.
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
