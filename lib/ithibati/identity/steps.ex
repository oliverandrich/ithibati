defmodule Ithibati.Identity.Steps do
  @moduledoc false

  # Multi fragments share the `:account` default and the `account:` override.

  alias Ithibati.Config

  @default :account

  def name(opts), do: Keyword.get(opts, :account, @default)

  # Report step names without inspecting their values, which may contain secrets.
  def account!(changes, opts) do
    step = name(opts)

    case changes do
      %{^step => account} ->
        Config.account!(account)

      _otherwise ->
        raise ArgumentError,
              "no step named #{inspect(step)} in this multi — this library's fragments read the " <>
                "account from the step that created it, and take its name as `account:`. " <>
                "Steps so far: #{inspect(Map.keys(changes))}"
    end
  end

  # Standalone invitation acceptance permits a missing account step. A present step must
  # still contain an account from the configured schema.
  def account(changes, opts) do
    case Map.fetch(changes, name(opts)) do
      {:ok, account} -> {:ok, Config.account!(account)}
      :error -> :error
    end
  end
end
