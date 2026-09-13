defmodule Ithibati.Schema.IdentifierFormatsTest do
  @moduledoc """
  The two patterns this library offers. Both are *offered*, so what they refuse is the reason they
  exist — a format that accepted everything would be a format nobody needed.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Schema.Identifier

  describe "username_format/0, which is Mastodon's rule for a local account" do
    test "takes letters, digits and underscores" do
      for value <- ~w(alice a alice_smith a1 _ 0123456789) do
        assert Regex.match?(Identifier.username_format(), value), "refused #{inspect(value)}"
      end
    end

    # Each of these is a way to stand beside somebody else's name and be mistaken for them, which
    # is the whole reason to borrow a rule that a large number of people have tried to game.
    test "and refuses every way of looking like somebody else" do
      for {value, why} <- [
            {"alice.smith", "a dot beside the same name without one"},
            {"alice-smith", "a hyphen, the same"},
            {"аlice", "a Cyrillic а where a Latin a is expected"},
            {"alice smith", "a space"},
            {"alice@example.com", "an address, which is the other format's job"}
          ] do
        refute Regex.match?(Identifier.username_format(), value), "accepted #{why}"
      end
    end

    test "and stops at thirty characters, which is where Mastodon stops" do
      assert Regex.match?(Identifier.username_format(), String.duplicate("a", 30))
      refute Regex.match?(Identifier.username_format(), String.duplicate("a", 31))
    end

    # The pattern has no `i` flag and does not need one: `steps/4` normalises before it validates,
    # so `Alice` reaches the pattern as `alice`. That ordering is also why `Alice` and `alice`
    # cannot become two accounts, which matters more than the flag does.
    test "and never sees an uppercase letter, because normalisation runs first" do
      refute Regex.match?(Identifier.username_format(), "Alice")
      assert Regex.match?(Identifier.username_format(), Identifier.normalize("  Alice  "))
    end
  end

  describe "email_format/0" do
    test "takes an address and refuses a quoted local part with a space in it" do
      assert Regex.match?(Identifier.email_format(), "you@example.com")
      assert Regex.match?(Identifier.email_format(), "you@localhost")
      refute Regex.match?(Identifier.email_format(), ~s("a b"@example.com))
    end
  end

  # `$` matches before a trailing newline and `\z` does not, and both patterns are documented as
  # something an application calls directly — into its own `validate_format/3`, where nothing has
  # trimmed the value first. One value per pattern, and it has to be a value that pattern would
  # otherwise accept: refusing `"alice\n"` proves nothing about `email_format/0`, which refuses it
  # for the missing `@` whichever anchors it uses.
  test "neither pattern lets a trailing newline past the end" do
    for {name, format, value} <- [
          {"username_format/0", Identifier.username_format(), "alice\n"},
          {"email_format/0", Identifier.email_format(), "you@example.com\n"}
        ] do
      assert Regex.match?(format, String.trim_trailing(value)),
             "#{name} refuses #{inspect(String.trim_trailing(value))}, so the newline proves nothing"

      refute Regex.match?(format, value), "#{name} accepted #{inspect(value)}"
    end
  end
end
