defmodule Ithibati.Credo.NoInternalCallsTest do
  @moduledoc """
  The rule that reads the library rather than a list.

  Every case here names a real function of this library, because that is the whole mechanism: the
  check asks the compiled module whether it is documented. A fixture invented for the test would
  prove nothing about what it will say tomorrow.
  """
  use Credo.Test.Case, async: true

  alias Ithibati.Credo.NoInternalCalls

  defp check(source),
    do: source |> to_source_file("lib/app/accounts.ex") |> run_check(NoInternalCalls)

  describe "it reports" do
    test "a function this library marked @doc false" do
      """
      defmodule App.Accounts do
        def normalise(value), do: Ithibati.Schema.Identifier.validated_format!(value)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "validated_format!"
        assert issue.message =~ "internal to this library"
      end)
    end

    test "anything at all in a module marked @moduledoc false" do
      """
      defmodule App.Accounts do
        def digest(token), do: Ithibati.Identity.Secrets.digest(token)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    test "the same through an alias" do
      """
      defmodule App.Accounts do
        alias Ithibati.Identity.Secrets

        def digest(token), do: Secrets.digest(token)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    test "and through an alias that renamed it" do
      """
      defmodule App.Accounts do
        alias Ithibati.Identity.Secrets, as: Crypto

        def digest(token), do: Crypto.digest(token)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    test "and through a multi-alias" do
      """
      defmodule App.Accounts do
        alias Ithibati.Identity.{Secrets, Tokens}

        def digest(token), do: Secrets.digest(token)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    # A pipe carries one argument fewer than the call it stands for, and the arity is what the
    # documentation is looked up by.
    test "a piped call, at the arity the function actually has" do
      """
      defmodule App.Accounts do
        def enrol(attrs), do: %Ithibati.UserKey{} |> Ithibati.UserKey.changeset(attrs)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "Ithibati.UserKey.changeset/2" end)
    end

    test "a capture, which carries its arity and no arguments" do
      """
      defmodule App.Accounts do
        def all(list), do: Enum.map(list, &Ithibati.Schema.Identifier.validated_format!/1)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "validated_format!/1" end)
    end

    test "a call that leaves a default argument out" do
      """
      defmodule App.Accounts do
        def codes(repo, account), do: Ithibati.Identity.RecoveryCodes.issue!(repo, account)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "issue!/3" end)
    end

    test "a call down through an aliased parent" do
      """
      defmodule App.Accounts do
        alias Ithibati.Identity

        def digest(t), do: Identity.Secrets.digest(t)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    test "an underscored function this library marked itself" do
      """
      defmodule App.Accounts do
        def force(a, b), do: Ithibati.Schema.User.__changeset__(a, b, :email, nil, nil)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.message =~ "__changeset__/5" end)
    end
  end

  describe "it leaves alone" do
    # Two modules in one file can alias the same last segment to different things, and this walk
    # has no notion of which is in scope where. Naming a module the source does not contain is
    # worse than saying nothing, so an ambiguous name is dropped.
    test "a name that two modules in one file alias differently" do
      """
      defmodule App.A do
        alias Ithibati.Identity.Secrets
        def a(t), do: Secrets.digest(t)
      end

      defmodule App.B do
        alias App.Crypto.Secrets
        def b(t), do: Secrets.digest(t)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "the documented surface, which is the point of having one" do
      """
      defmodule App.Accounts do
        def format, do: Ithibati.Schema.Identifier.email_format()
        def mint(account), do: Ithibati.Identity.Sessions.generate_session_token(account)
        def claim(attrs), do: Ithibati.Bootstrap.changeset(%Ithibati.Bootstrap{}, attrs)
      end
      """
      |> check()
      |> refute_issues()
    end

    # Hidden because Ecto and Phoenix say so, not because this library decided anything — and a
    # consumer reads a schema's own source through one of them.
    test "reflection a `use` generated" do
      """
      defmodule App.Accounts do
        def table, do: Ithibati.UserKey.__schema__(:source)
        def blank, do: %Ithibati.UserKey{}
      end
      """
      |> check()
      |> refute_issues()
    end

    test "somebody else's module that happens to share a name" do
      """
      defmodule App.Accounts do
        alias App.Crypto.Secrets

        def digest(token), do: Secrets.digest(token)
      end
      """
      |> check()
      |> refute_issues()
    end

    # Its name is not a name at all, and none of the alias clauses can read it — which is the
    # point: they pass over it instead of handing `Module.concat/1` something it refuses, and a
    # raise inside a check aborts the whole Credo run rather than reporting anything.
    test "an alias whose name is computed, beside a call that is ours" do
      """
      defmodule App.Accounts do
        alias Ithibati.{unquote(mod)}

        def digest(t), do: Ithibati.Identity.Secrets.digest(t)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "digest" end)
    end

    test "a bare name this file never aliased" do
      """
      defmodule App.Accounts do
        def digest(token), do: Secrets.digest(token)
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  # The claim the rule rests on, put to a module the check has never heard of:
  # `Ithibati.SurfaceProbe` is named nowhere in it, and one of its two functions is reported
  # purely because the compiled module says so.
  test "what counts as internal comes from the compiled module, not from this check" do
    refute File.read!("lib/ithibati/credo/no_internal_calls.ex") =~ "SurfaceProbe"

    """
    defmodule App.Accounts do
      def a, do: Ithibati.SurfaceProbe.closed()
      def b, do: Ithibati.SurfaceProbe.open()
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "closed" end)
  end
end
