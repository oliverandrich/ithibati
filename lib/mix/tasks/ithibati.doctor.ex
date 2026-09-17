defmodule Mix.Tasks.Ithibati.Doctor do
  @shortdoc "Says what is wrong with this application's Ithibati setup"

  @moduledoc """
  Starts the consuming application, prints setup findings and fails if any check reports an error.

      mix ithibati.doctor

  Run the task inside the application that configures Ithibati, not at an umbrella root. It needs
  working configuration and a reachable database for the database checks.

  The output labels findings `ok`, `bad` or `skip`. A run with no errors prints `Nothing to fix.`.
  See [Setup checks](doctor.md) for interpreting and correcting failures.
  """

  use Mix.Task

  alias Ithibati.Doctor

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    results = Doctor.examine(app!())

    Enum.each(results, &say/1)

    case Enum.count(results, &match?({_, {:error, _}}, &1)) do
      0 -> Mix.shell().info("\nNothing to fix.")
      count -> Mix.raise("#{count} #{if count == 1, do: "thing", else: "things"} to fix.")
    end
  end

  # An umbrella root has `apps_path:` and no `:app`, so there is no application to examine and
  # nothing here could find the child that owns the router. Saying so beats reporting a correctly
  # wired umbrella as having no routes.
  defp app! do
    Mix.Project.config()[:app] ||
      Mix.raise(
        "run this inside the application that uses Ithibati — there is no application here, " <>
          "which is how an umbrella root looks."
      )
  end

  defp say({subject, {status, detail}}) do
    Mix.shell().info(IO.ANSI.format([mark(status), " ", subject, "\n    ", detail]))
  end

  # A word, not colour alone. This output is read in CI logs as often as in a terminal.
  defp mark(:ok), do: [:green, "ok  "]
  defp mark(:error), do: [:red, "bad "]
  defp mark(:skip), do: [:yellow, "skip"]
end
