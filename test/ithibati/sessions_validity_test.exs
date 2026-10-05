defmodule Ithibati.Identity.SessionsValidityTest do
  @moduledoc """
  How long a session lives, and what this library says when the setting that decides it is wrong.

  Not async: it moves the application environment `Ithibati.Identity.Sessions` reads. The paths
  that need no such move live in `Ithibati.Identity.SessionsTest`.
  """
  use Ithibati.DataCase, async: false

  alias Ithibati.Identity.Sessions

  setup do
    %{user: user_fixture()}
  end

  test "a session has a validity even when the application configures none", %{user: user} do
    delete_env(:ithibati, :session_validity)

    token = Sessions.generate_session_token(user)

    assert Sessions.get_user_by_session_token(token)
    refute backdated(token, days(61)) |> Sessions.get_user_by_session_token()
  end

  test "an application may set its own", %{user: user} do
    put_env(:ithibati, session_validity: {1, :second})

    token = Sessions.generate_session_token(user)

    refute backdated(token, 5) |> Sessions.get_user_by_session_token()
  end

  # The arithmetic is `DateTime.shift/2`'s, so what is worth pinning is not how many seconds are
  # in a day but that the unit reaches it at all: read as days, this session lives five days, and
  # read as anything else it would not.
  test "the unit is honoured, not only the number", %{user: user} do
    put_env(:ithibati, session_validity: {5, :day})

    assert Sessions.generate_session_token(user)
           |> backdated(days(4))
           |> Sessions.get_user_by_session_token()

    refute Sessions.generate_session_token(user)
           |> backdated(days(6))
           |> Sessions.get_user_by_session_token()
  end

  # A browser keeps the session cookie only as long as it is told to. This is what to tell it, so
  # the cookie and the session end together.
  test "the validity reads as a cookie's max age in seconds" do
    delete_env(:ithibati, :session_validity)
    assert Sessions.max_age() == 60 * 86_400

    put_env(:ithibati, session_validity: {2, :week})
    assert Sessions.max_age() == 2 * 7 * 86_400

    put_env(:ithibati, session_validity: {90, :minute})
    assert Sessions.max_age() == 5400

    put_env(:ithibati, session_validity: {0, :day})
    assert_raise ArgumentError, ~r/session_validity/, fn -> Sessions.max_age() end
  end

  test "cleanup uses the configured validity", %{user: user} do
    put_env(:ithibati, session_validity: {1, :hour})
    user |> Sessions.generate_session_token() |> backdated(7200)
    valid = user |> Sessions.generate_session_token() |> backdated(1800)

    assert Sessions.delete_expired() == 1
    assert Sessions.get_user_by_session_token(valid)
  end

  test "cleanup refuses invalid validity before deleting anything", %{user: user} do
    user |> Sessions.generate_session_token() |> backdated(days(90))
    put_env(:ithibati, session_validity: {0, :day})

    assert_raise ArgumentError, ~r/expected \{count, unit\}/, fn -> Sessions.delete_expired() end
    assert TestRepo.aggregate(Ithibati.Session, :count) == 1
  end

  describe "a setting this library will not run on" do
    # One refusal covers all of them, so the rows are the values alone. The one row that makes a
    # claim of its own — that the refusal echoes what was written — is the test below.
    @rejected [
      {"a count of zero", {0, :day}},
      {"something that is not a validity at all", 90},
      {"a keyword list, the idiom the other settings here use", [count: 90, unit: :day]},
      {"nil", nil}
    ]

    for {name, value} <- @rejected do
      test name, %{user: user} do
        put_env(:ithibati, session_validity: unquote(Macro.escape(value)))

        assert_raise ArgumentError, ~r/expected \{count, unit\}/, fn ->
          Sessions.generate_session_token(user)
        end
      end
    end

    test "and the refusal quotes what was written, so the typo is findable", %{user: user} do
      put_env(:ithibati, session_validity: {3, :month})

      assert_raise ArgumentError, ~r/:month.*expected \{count, unit\}/s, fn ->
        Sessions.generate_session_token(user)
      end
    end
  end
end
