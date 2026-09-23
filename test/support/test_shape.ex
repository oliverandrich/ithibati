defmodule Ithibati.TestShape do
  @moduledoc """
  A format and a message an instance chooses while it runs, for the tests that ask whether the
  library can be told to ask rather than to remember.

  The choice lives in the process dictionary, not in the application environment, although the
  application environment is what a real deployment would use. Two `async: true` modules ask this
  module for a shape, and a global key would have them overwrite each other's answer. The
  changeset is built in the test's own process, so a per-process seam says the same thing without
  the race: what the library reads, it reads when the changeset runs.
  """
  alias Ithibati.Schema.Identifier

  @key :ithibati_test_identifier_shape

  @doc "Chooses the shape for the calling process. `:username` unless a test says otherwise."
  # `:ok` rather than what `Process.put/2` answers with, which is the previous value and therefore
  # `nil` the first time. A `setup` block ending in `nil` is refused by ExUnit.
  def choose(shape) when shape in [:username, :email] do
    Process.put(@key, shape)
    :ok
  end

  def format do
    case Process.get(@key, :username) do
      :username -> Identifier.username_format()
      :email -> Identifier.email_format()
    end
  end

  def message do
    case Process.get(@key, :username) do
      :username -> "must be a name"
      :email -> "must be an address"
    end
  end

  @doc "A function that exists and answers with the wrong thing, which is its whole purpose."
  def not_a_pattern, do: "~r/looks like one/"
end
