defmodule Ithibati.Credo.NoDirectTableAccessTest do
  @moduledoc """
  What the rule reports, and — the half that decides whether it can be switched on — what it
  leaves alone.

  A check that only ever fires is as useless as one that never does: a consumer whose own code is
  flagged for handling a struct this library handed them turns the rule off, and then it guards
  nothing at all.
  """
  use Credo.Test.Case, async: true

  alias Ithibati.Credo.NoDirectTableAccess

  defp check(source),
    do: source |> to_source_file("lib/app/accounts.ex") |> run_check(NoDirectTableAccess)

  describe "it reports" do
    test "a query whose source is one of this library's schemas" do
      """
      defmodule App.Accounts do
        import Ecto.Query

        def sessions(account) do
          from(t in Ithibati.UserToken, where: t.user_id == ^account.id)
        end
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "UserToken"
        assert issue.message =~ "reach it through Ithibati.Identity"
      end)
    end

    test "the same query written through an alias" do
      """
      defmodule App.Accounts do
        import Ecto.Query
        alias Ithibati.RecoveryCode

        def codes(account), do: from(c in RecoveryCode, where: c.user_id == ^account.id)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "RecoveryCode" end)
    end

    test "a repo call that names the schema instead of querying it" do
      """
      defmodule App.Accounts do
        def key(id), do: App.Repo.get(Ithibati.UserKey, id)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "UserKey" end)
    end

    test "a bulk write, which is the one that skips the most" do
      """
      defmodule App.Accounts do
        def wipe(account), do: App.Repo.delete_all(Ithibati.RecoveryCode)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "RecoveryCode" end)
    end

    # The spelling Ecto users actually write, and the one a shape-matching check misses.
    test "a pipe into a repo, which is how most of this is written" do
      """
      defmodule App.Accounts do
        def sessions, do: Ithibati.UserToken |> App.Repo.all()
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "UserToken" end)
    end

    test "a join, which is the quiet way to reach a table you were not given" do
      """
      defmodule App.Accounts do
        import Ecto.Query

        def with_tokens do
          from(u in App.Accounts.User, join: t in Ithibati.UserToken, on: t.user_id == u.id)
        end
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "UserToken" end)
    end

    test "a repo that is not spelled Repo" do
      """
      defmodule App.Accounts do
        def key(id), do: App.Database.get(Ithibati.UserKey, id)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "UserKey" end)
    end

    # It reports through the `in` position, not the remote call — that clause sees the `in` node
    # as its first argument and passes. So what this pins is that the qualified form is reported
    # exactly once rather than twice.
    test "a fully qualified Ecto.Query.from, once and not twice" do
      """
      defmodule App.Accounts do
        def all, do: Ecto.Query.from(t in Ithibati.UserToken)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "UserToken" end)
    end

    # The route a module-keyed rule would otherwise leave wide open.
    test "a table of ours named as a string" do
      """
      defmodule App.Accounts do
        import Ecto.Query
        def all, do: from(t in "ithibati_tokens")
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "ithibati_tokens" end)
    end

    test "and a schema of one's own declared over one of our tables" do
      """
      defmodule App.Token do
        use Ecto.Schema
        schema "ithibati_tokens" do
        end
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "ithibati_tokens" end)
    end

    test "each of the four, so none is quietly unguarded" do
      for schema <- ~w(UserKey RecoveryCode UserToken Bootstrap) do
        """
        defmodule App.Accounts do
          import Ecto.Query
          def all, do: from(x in Ithibati.#{schema})
        end
        """
        |> check()
        |> assert_issue(fn issue -> assert issue.trigger == schema end)
      end
    end
  end

  describe "it leaves alone" do
    # The reason a consumer can switch this on at all: this library hands these structs out, and
    # handling one is the ordinary thing to do with it.
    test "a struct this library handed back" do
      """
      defmodule App.Accounts do
        def label(%Ithibati.UserKey{} = key), do: key.id
      end
      """
      |> check()
      |> refute_issues()
    end

    test "an alias directive on its own" do
      """
      defmodule App.Accounts do
        alias Ithibati.UserToken

        def type, do: UserToken
      end
      """
      |> check()
      |> refute_issues()
    end

    # Without this the rule is unusable: `Bootstrap` is a name plenty of applications have, and
    # being told to read their own module through `Ithibati.Identity` is how a rule gets switched
    # off for good.
    test "a module of the application's own that happens to share a name" do
      """
      defmodule App.Accounts do
        import Ecto.Query
        def all, do: from(b in App.Bootstrap)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "and a bare name that was never aliased from this library" do
      """
      defmodule App.Accounts do
        import Ecto.Query
        alias App.Bootstrap

        def all, do: from(b in Bootstrap)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "a query against the application's own schemas" do
      """
      defmodule App.Accounts do
        import Ecto.Query
        def users, do: from(u in App.Accounts.User)
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  # Why it must not scope by filename, and what follows from that for this repository's own
  # `.credo.exs`, is in `Ithibati.Credo.ConfigTest`.
  test "the same source anywhere else is reported just the same" do
    """
    defmodule Anything do
      import Ecto.Query
      def all, do: from(t in Ithibati.UserToken)
    end
    """
    |> to_source_file("lib/ithibati/identity/tokens.ex")
    |> run_check(NoDirectTableAccess)
    |> assert_issue()
  end
end
