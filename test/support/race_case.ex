defmodule Ithibati.RaceCase do
  @moduledoc """
  Test case for a module that proves something about two callers arriving at once.

  Not `Ithibati.DataCase`, and the difference is the whole point: that one checks out a sandboxed
  connection per test and rolls it back, which leaves a single connection and so no race to lose.
  Here the sandbox is switched off, every racer gets its own connection, and what they write is
  committed — so each module cleans up after itself.

  What this template owns is the part that must not be forgotten: switching the sandbox back on
  afterwards. Left off in one module, every module that runs after it is unsandboxed too, and the
  failures appear in files nobody touched.

  Measured, because it is worth knowing what this does and does not buy: removing that `on_exit`
  leaves the whole suite green, at three seeds. What would notice is a module running later that
  depends on its writes being rolled back, and today none of them does — the day one does, the
  failure appears in that module rather than here. The restore is therefore guarded by no test, and
  that is the argument for it living here, where a module cannot omit what it does not write, rather
  than in four copies where one day one copy would.

  The cleanup below is the opposite case and shows what the same omission costs when something *does*
  notice: removing it fails between three and twenty tests depending on the seed, none of them in a
  module anybody changed.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.TestRepo

  using opts do
    # Never async: every module here drives a second process against a connection this one does not
    # own. Refused rather than overruled, so that asking for it gets an answer.
    opts[:async] &&
      raise ArgumentError, "Ithibati.RaceCase is never async — the sandbox is off for these"

    quote do
      use ExUnit.Case, async: false

      import Ithibati.RaceCase

      alias Ithibati.TestRepo

      # Committed rather than rolled back, so each module says what it leaves behind. Here rather
      # than in each module for the same reason as the restore above: a module cannot forget what it
      # does not write, and forgetting means the next module inherits the rows.
      setup do
        on_exit(&clear/0)
      end
    end
  end

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  @doc """
  Runs `fun` over every element at once and answers what each call returned, in order.

  The pool is checked here rather than in `setup_all`, because here is where the number is known: a
  machine with fewer connections than racers runs them as a queue, and "exactly one won" then holds
  for the wrong reason — which is the one thing these modules exist to rule out. A floor asserted
  against a constant somewhere else would pass while a module quietly raised its own count.

  An element that never finishes is a failure of this test rather than a result to count, so it
  fails here with the reason rather than arriving as an unmatched tuple further down.
  """
  def racing(items, fun) do
    racers = Enum.count(items)
    pool = TestRepo.config()[:pool_size]

    assert racers > 1, "#{racers} racers is not a race"

    assert pool >= racers,
           "pool_size is #{pool}, so only that many of #{racers} racers can be in flight at once"

    items
    |> Task.async_stream(fun, max_concurrency: racers)
    |> Enum.map(fn
      {:ok, outcome} -> outcome
      {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
    end)
  end
end
