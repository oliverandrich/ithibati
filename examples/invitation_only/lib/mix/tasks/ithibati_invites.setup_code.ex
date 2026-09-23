defmodule Mix.Tasks.IthibatiInvites.SetupCode do
  @moduledoc "Issues an operator code for this example's first account claim."
  use Mix.Task

  @shortdoc "Issue or replace the first-account operator code"
  @requirements ["app.start"]

  @impl true
  def run(_args) do
    case Ithibati.Identity.Instance.issue_code() do
      {:ok, code} -> Mix.shell().info("Initial setup code: #{code}")
      {:error, :already_claimed} -> Mix.raise("the instance has already been claimed")
      {:error, :claim_is_open} -> Mix.raise("set initial_claim: :operator_code to use a code")
    end
  end
end
