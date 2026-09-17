defmodule Ithibati.DoctorTest do
  @moduledoc """
  What the doctor says, and — the half that matters — that it says something when asked about a
  broken application.

  A check that has only ever been seen passing is not a check. Every question here is asked twice:
  once of this suite's own application, which is set up correctly, and once of one broken on
  purpose. The database questions are broken by dropping inside the test's own transaction, which
  the sandbox rolls back.
  """
  use Ithibati.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ithibati.Doctor
  alias Ithibati.TestKey

  # Configured, loadable, a real Ecto repo — and never started. The shape an application has when
  # somebody names a repo they have not put in their supervision tree.
  defmodule UnstartedRepo do
    use Ecto.Repo, otp_app: :ithibati, adapter: Ecto.Adapters.Postgres
  end

  defmodule UnsupportedRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
  end

  defp subjects(results, status),
    do: for({subject, {^status, _detail}} <- results, do: subject)

  defp detail(results, subject) do
    {_subject, {_status, detail}} = List.keyfind!(results, subject, 0)
    detail
  end

  describe "an application that is set up correctly" do
    test "is told so, and nothing is reported wrong" do
      results = Doctor.examine(:ithibati)

      assert subjects(results, :error) == []
      assert "config :ithibati, repo:" in subjects(results, :ok)
      assert "the database adapter" in subjects(results, :ok)
      assert "the repo answers" in subjects(results, :ok)
      assert "this library's tables" in subjects(results, :ok)
      assert "config :ithibati, users_key_type:" in subjects(results, :ok)
    end

    # The subjects and not the statuses: the leg without the optional dependencies has no web
    # half, so the routes question is skipped there and rightly.
    test "and says nothing about wax_, which is what an application that set none looks like" do
      delete_env(:wax_, :rp_id)
      delete_env(:wax_, :origin)

      assert "config :wax_" in subjects(Doctor.examine(:ithibati), :ok)
    end

    test "and every question is asked, so a silent omission cannot pass for health" do
      assert Enum.map(Doctor.examine(:ithibati), &elem(&1, 0)) == [
               "config :ithibati, repo:",
               "the database adapter",
               "the repo answers",
               "config :ithibati, user_schema:",
               "config :ithibati, invitation_schema:",
               "config :ithibati, session_validity:",
               "this library's tables",
               "config :ithibati, users_key_type:",
               "the identifier's unique index",
               "the invitation table",
               "config :wax_",
               "the ceremony routes",
               "the handler's callbacks",
               "the handler each mount names"
             ]
    end
  end

  # Both of these are the questions nothing else can ask. An application that turns invitations
  # on after the migration has run never runs it again, so the table it just made is checked by
  # this or by nothing; and a handler missing a callback is a compiler *warning*, which an
  # application not built with `--warnings-as-errors` never sees.
  describe "the questions that catch what compiles and migrates anyway" do
    test "an invitation table that has the index reports so" do
      assert "the invitation table" in subjects(Doctor.examine(:ithibati), :ok)
    end

    # Dropped inside the test's own transaction, the way the missing-table test above does it:
    # this is a real index that is really gone, not a stubbed answer about one.
    test "an invitation table whose token_hash lost its unique index" do
      SQL.query!(Ithibati.TestRepo, "DROP INDEX invitations_token_hash_index", [])

      results = Doctor.examine(:ithibati)

      assert "the invitation table" in subjects(results, :error)
      detail = detail(results, "the invitation table")
      assert detail =~ "no unique index"
      assert detail =~ "invitation_index"
    end

    test "an invitation table that is configured and not there" do
      SQL.query!(Ithibati.TestRepo, "DROP TABLE invitations CASCADE", [])

      assert detail(Doctor.examine(:ithibati), "the invitation table") =~ "there is no table"
    end

    # Guarded the way the web tests are: without the optional dependencies there is no behaviour
    # to implement and no handler in the estate, and the question is skipped rather than asked.
    if Code.ensure_loaded?(Phoenix.Component) do
      test "a handler with all four callbacks reports so" do
        assert "the handler's callbacks" in subjects(Doctor.examine(:ithibati), :ok)
      end

      # `Ithibati.Doctor` writes the list out, because it compiles in the build that has no web
      # half and so cannot ask the behaviour. Here the behaviour exists, so this is where the copy
      # is held to it: a fifth required callback would otherwise go unchecked by the one check
      # whose purpose is to notice a missing one.
      test "the callbacks it requires are the ones the behaviour declares" do
        alias Ithibati.Web.Handler

        declared =
          Handler.behaviour_info(:callbacks) -- Handler.behaviour_info(:optional_callbacks)

        assert Enum.sort(Doctor.required_callbacks()) == Enum.sort(declared)
      end

      # `Ithibati.TestExtensionHandler` declares `@behaviour Plug` in front of ours, the way a
      # handler written on a controller does. Reading one `behaviour` attribute finds that first
      # one and reports that nobody implements the behaviour at all — from the check whose whole
      # purpose is to notice a missing callback.
      test "and one that declares another behaviour first is found behind it" do
        assert detail(Doctor.examine(:ithibati), "the handler's callbacks") =~
                 "Ithibati.TestExtensionHandler"
      end

      # The judgement is checked against a module rather than through `examine/1`, because a
      # module that declares the behaviour and omits a callback is a compile warning — which
      # this suite runs as an error, and rightly. The test above proves the judgement is
      # reached; this one proves what it judges.
      test "a handler missing a callback is named, with the callback" do
        assert {Ithibati.TestHandler, []} = Doctor.missing_callbacks(Ithibati.TestHandler)

        assert {Ithibati.TestPageController, missing} =
                 Doctor.missing_callbacks(Ithibati.TestPageController)

        assert {:recovered, 3} in missing
        assert {:register, 4} in missing
      end

      test "and the handlers the routers mount are named as reachable" do
        results = Doctor.examine(:ithibati)

        # The status first: the sentence a fault produces names the handler too, so matching the
        # name alone cannot tell a healthy answer from a broken one.
        assert "the handler each mount names" in subjects(results, :ok)
        assert detail(results, "the handler each mount names") =~ "Ithibati.TestHandler"
      end

      # Judged against a module rather than through `examine/1`, because a permanently broken
      # mount would have to live in `test/support/`, where it compiles into this application and
      # would make the suite's own run report an error for ever.
      test "a mount naming a module nobody defined is told apart from an incomplete one" do
        assert Doctor.mount_fault(Ithibati.TestHandler) == nil
        assert Doctor.mount_fault(Ithibati.NoSuchHandler) == :not_loaded

        assert {:missing, missing} = Doctor.mount_fault(Ithibati.TestPageController)
        assert {:recovered, 3} in missing
      end
    end
  end

  describe "an unsupported database adapter" do
    test "reports the adapter without querying it and continues independent checks" do
      put_env(:ithibati, :repo, UnsupportedRepo)

      results = Doctor.examine(:ithibati)

      assert subjects(results, :error) == ["the database adapter"]

      assert detail(results, "the database adapter") ==
               "Ithibati requires PostgreSQL; #{inspect(UnsupportedRepo)} uses Ecto.Adapters.SQLite3."

      for subject <- [
            "the repo answers",
            "this library's tables",
            "config :ithibati, users_key_type:",
            "the identifier's unique index",
            "the invitation table"
          ] do
        assert {^subject, {:skip, "the database adapter is not supported"}} =
                 List.keyfind!(results, subject, 0)
      end

      assert "config :ithibati, user_schema:" in subjects(results, :ok)
      assert "config :ithibati, session_validity:" in subjects(results, :ok)
      assert "config :wax_" in subjects(results, :ok)

      if Code.ensure_loaded?(Phoenix.Component) do
        assert "the ceremony routes" in subjects(results, :ok)
        assert "the handler's callbacks" in subjects(results, :ok)
      end
    end
  end

  describe "configuration it refuses" do
    test "a repo nobody configured, and the questions that needed it are skipped, not crashed" do
      delete_env(:ithibati, :repo)

      results = Doctor.examine(:ithibati)

      assert detail(results, "config :ithibati, repo:") =~ "config :ithibati, repo: MyApp.Repo"
      assert "the database adapter" in subjects(results, :skip)
      assert "the repo answers" in subjects(results, :skip)
      assert "this library's tables" in subjects(results, :skip)
      assert "config :ithibati, users_key_type:" in subjects(results, :skip)
    end

    test "a user schema that does not use the macro" do
      put_env(:ithibati, :user_schema, Ithibati.DoctorTest)

      assert detail(Doctor.examine(:ithibati), "config :ithibati, user_schema:") =~
               "does not `use Ithibati.Schema.User`"
    end

    test "a token validity nobody can read" do
      put_env(:ithibati, :session_validity, {0, :fortnight})

      assert detail(Doctor.examine(:ithibati), "config :ithibati, session_validity:") =~
               "expected {count, unit}"
    end

    # The one that looks like configuration and is not: `wax_` reads these as its own defaults, and
    # this library passes both per call, so whatever is set here is never consulted.
    test "a wax_ relying party, which this library never reads" do
      put_env(:wax_, :rp_id, "example.test")

      assert detail(Doctor.examine(:ithibati), "config :wax_") =~ "rp_id"
    end
  end

  describe "a repo that is configured and does not answer" do
    # The whole list is built before a line of it is printed, so an exception here costs the
    # reader every other answer — including the one that says what is wrong.
    test "is reported, and the questions that needed it are skipped rather than raising" do
      put_env(:ithibati, :repo, UnstartedRepo)

      results = Doctor.examine(:ithibati)

      assert "the database adapter" in subjects(results, :ok)
      assert "the repo answers" in subjects(results, :error)
      assert detail(results, "this library's tables") == "the repo did not answer"
      assert detail(results, "config :ithibati, users_key_type:") == "the repo did not answer"
    end
  end

  describe "the database" do
    # Dropped inside the test's own transaction: the sandbox rolls it back, so this is a real
    # missing table rather than a stubbed answer about one.
    test "a table the migration should have created and did not" do
      SQL.query!(Ithibati.TestRepo, "DROP TABLE ithibati_bootstrap CASCADE", [])

      detail = detail(Doctor.examine(:ithibati), "this library's tables")

      assert detail =~ "ithibati_bootstrap"
      assert detail =~ "migration"
    end

    test "an account table whose key is not the configured type" do
      SQL.query!(
        Ithibati.TestRepo,
        "CREATE TABLE wrong_key (id text PRIMARY KEY)",
        []
      )

      assert {:error, message} = Doctor.key_type(Ithibati.TestRepo, nil, "wrong_key")
      assert message =~ "users_key_type"
      assert message =~ "text"
    end

    # The column has to carry the type this suite is configured for, or the type branch answers
    # first and this test passes while measuring the wrong refusal.
    # A table that is there but has no such column is a different mistake from one that is not
    # there.
    test "an account table without the column the foreign keys point at" do
      SQL.query!(Ithibati.TestRepo, "CREATE TABLE odd_key (user_id bigint PRIMARY KEY)", [])

      assert {:error, message} = Doctor.key_type(Ithibati.TestRepo, nil, "odd_key")
      assert message =~ "has no column id"
      refute message =~ "there is no table"
    end

    # `:migration_foreign_key` holds options, not a name. Read as a bare name it is a keyword
    # list, which reaches Postgres as a column and raises on the way — taking the whole run with
    # it, because the list is built before anything is printed.
    test "an account whose foreign keys point at a column the repo renamed" do
      put_env(
        :ithibati,
        Ithibati.TestRepo,
        Keyword.put(
          Application.get_env(:ithibati, Ithibati.TestRepo),
          :migration_foreign_key,
          column: :user_id
        )
      )

      SQL.query!(
        Ithibati.TestRepo,
        "CREATE TABLE renamed_key (user_id #{TestKey.postgres_type()} PRIMARY KEY)",
        []
      )

      assert {:ok, detail} = Doctor.key_type(Ithibati.TestRepo, nil, "renamed_key")
      assert detail =~ "renamed_key.user_id"
    end

    # Dropped inside the transaction, so this is the real index gone rather than a stubbed answer.
    # Nothing but the doctor asks this after the migration has run.
    test "an identifier column whose unique index somebody dropped" do
      SQL.query!(Ithibati.TestRepo, "DROP INDEX users_email_index", [])

      detail = detail(Doctor.examine(:ithibati), "the identifier's unique index")

      assert detail =~ "users.email carries no unique index"

      # What the missing index actually costs, so the message cannot drift back into naming a
      # lookup this library does not perform.
      assert detail =~ "both pass the changeset and both insert"
    end

    test "an account table with no unique index on the column the keys point at" do
      SQL.query!(Ithibati.TestRepo, "CREATE TABLE no_unique (id #{TestKey.postgres_type()})", [])

      assert {:error, message} = Doctor.key_type(Ithibati.TestRepo, nil, "no_unique")
      assert message =~ "carries no unique index"
      refute message =~ "users_key_type"
    end
  end
end
