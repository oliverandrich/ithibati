defmodule Ithibati.Credo.IdentityIsPortableTest do
  @moduledoc """
  The guard on the two rules the core stands on. A check nobody drives reports nothing and says so
  quietly, which is what a guard must not do.
  """
  use Credo.Test.Case

  alias Ithibati.Credo.IdentityIsPortable

  defp check(source, filename \\ "lib/ithibati/identity/tokens.ex") do
    source |> to_source_file(filename) |> run_check(IdentityIsPortable)
  end

  # The guard is a prefix, so a module added beside the others is covered without anyone editing the
  # check — which is the direction that matters, because forgetting leaves code *unguarded*.
  test "a module nested under the guarded namespace is guarded too" do
    """
    defmodule Ithibati.Identity.Passkeys do
      alias Ithibati.Sites
    end
    """
    |> check("lib/ithibati/identity/passkeys.ex")
    |> assert_issue(&assert(&1.trigger == "Ithibati.Sites"))
  end

  describe "the allow-list, which is the guarded module's alone" do
    test "naming a module outside it is reported" do
      """
      defmodule Ithibati.Identity do
        def web, do: Ithibati.Components.button()
      end
      """
      |> check()
      |> assert_issue(&assert(&1.trigger == "Ithibati.Components"))
    end

    test "a multi-alias hides nothing" do
      """
      defmodule Ithibati.Identity do
        alias Ithibati.{Components, UserKey}
        def x, do: Components.button() && UserKey.changeset(%{}, %{})
      end
      """
      |> check()
      |> assert_issue(&assert(&1.trigger == "Ithibati.Components"))
    end

    # The rule is what may be named, not what may not, so a module invented next year is refused
    # without anyone having to remember this file exists.
    test "a module nobody listed is refused as well" do
      """
      defmodule Ithibati.Identity do
        def x, do: Ithibati.SomethingNew.y()
      end
      """
      |> check()
      |> assert_issue()
    end

    test "the offending name on the first line after defmodule is reported at line two" do
      """
      defmodule Ithibati.Identity do
        alias Ithibati.Sessions
        @doc "Something."
        def x, do: Sessions.y()
      end
      """
      |> check()
      |> assert_issue(&assert(&1.line_no == 2))
    end

    test "what the core may name is left alone" do
      """
      defmodule Ithibati.Identity do
        alias Ithibati.{RecoveryCode, UserKey, UserToken}
        alias Ithibati.Config

        def get(id), do: Config.repo().get(UserKey, id)
        def codes, do: {RecoveryCode, UserToken}
      end
      """
      |> check()
      |> refute_issues()
    end

    # The two hand-cut exceptions, pinned: each is a clause of its own rather than an entry on the
    # allow-list, so a third `Ithibati.Schema.*` module is refused until somebody decides otherwise.
    test "and that includes the two schema contracts, but not their siblings" do
      """
      defmodule Ithibati.Identity.Passkeys do
        alias Ithibati.Schema.Identifier
        alias Ithibati.Schema.User

        def name(account), do: {User.passkey_display_name(account), Identifier.normalize("A")}
      end
      """
      |> check()
      |> refute_issues()

      """
      defmodule Ithibati.Identity.Passkeys do
        alias Ithibati.Schema.Invitation

        def invite, do: Invitation
      end
      """
      |> check()
      |> assert_issue()
    end

    # Neither a docstring nor a comment is a node, so the rule can say what it forbids.
    test "a doc and a comment may name anything" do
      """
      defmodule Ithibati.Identity do
        @moduledoc "Reaches into neither Ithibati.Components nor Phoenix.PubSub."
        # Unlike Phoenix.LiveView, this is fine.
        def x, do: :ok
      end
      """
      |> check()
      |> refute_issues()
    end

    test "another core module may name whatever it likes" do
      """
      defmodule Ithibati.UserToken do
        def x, do: Ithibati.Components.button()
      end
      """
      |> check("lib/ithibati/user_token.ex")
      |> refute_issues()
    end
  end

  describe "the optional dependencies, which every core module owes" do
    test "the guarded module may not name one" do
      """
      defmodule Ithibati.Identity do
        def sub, do: Phoenix.PubSub.subscribe(SomePubSub, "accounts")
      end
      """
      |> check()
      |> assert_issue(&assert(&1.trigger == "Phoenix.PubSub"))
    end

    # The reach the path-scoped version of this check did not have: the rule is a property of the
    # core, and the core is more than one file.
    test "so may no other core module" do
      """
      defmodule Ithibati.UserToken do
        def conn(c), do: Plug.Conn.put_status(c, 200)
      end
      """
      |> check("lib/ithibati/user_token.ex")
      |> assert_issue(&assert(&1.trigger == "Plug.Conn"))
    end

    test "the web half may name them freely" do
      """
      defmodule Ithibati.Web.Components do
        def sub, do: Phoenix.PubSub.subscribe(SomePubSub, "accounts")
      end
      """
      |> check("lib/ithibati/web/components.ex")
      |> refute_issues()
    end

    test "a file outside lib/ is none of this check's business" do
      """
      defmodule Ithibati.Support do
        def sub, do: Phoenix.PubSub.subscribe(SomePubSub, "accounts")
      end
      """
      |> check("test/support/thing.ex")
      |> refute_issues()
    end

    test "a module written out with its Elixir prefix is still refused" do
      """
      defmodule Ithibati.Identity do
        def sub, do: Elixir.Phoenix.PubSub.broadcast(P, "t", :x)
      end
      """
      |> check()
      |> assert_issue(&assert(&1.trigger == "Phoenix.PubSub"))
    end
  end

  # A `{…}` may hold something that is not an alias node at all. A raise here does not report an
  # issue — it aborts the whole Credo run.
  test "a multi-alias holding something that is not a module does not crash the run" do
    """
    defmodule Ithibati.Identity do
      defmacro a(m), do: quote(do: alias(Ithibati.{unquote(m)}))
    end
    """
    |> check()
    |> refute_issues()
  end
end
