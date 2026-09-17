defmodule Ithibati.Ceremony do
  @moduledoc """
  Lists the failure-code vocabulary produced by Ithibati's server and browser integration.

  The browser hook delivers codes as strings in `ithibati:failed` events. `codes/0` returns the
  fixed codes as atoms so applications can verify their message coverage:

      for code <- Ithibati.Ceremony.codes() do
        refute message(to_string(code)) =~ "Something went wrong"
      end

  The list does not include application-defined handler errors or the suffixed codes represented
  by `families/0`. Handle those separately or provide a fallback.
  [Handling failures](ceremonies.md#handling-failures) describes each code.
  """

  @server [
    :no_credentials,
    :no_challenge,
    :malformed_credential,
    :not_discoverable,
    :unknown_credential,
    :no_attested_credential,
    :credential_id_too_long,
    :already_enrolled,
    :invalid_code,
    :verification_failed
  ]

  # `already_enrolled` is in both on purpose, and `docs/ceremonies.md` says why.
  @browser [:already_enrolled, :ceremony_cancelled, :ceremony_failed, :recovery_failed, :unknown]

  @codes @server |> Enum.concat(@browser) |> Enum.uniq() |> Enum.sort()

  @families [:http, :missing_data]

  @doc "Every code this library can send, sorted."
  def codes, do: @codes

  @doc """
  Returns the prefixes of error-code families whose suffixes vary.

  `:http` represents codes such as `http_404`; `:missing_data` represents codes such as
  `missing_data_registration_url`. Match these by prefix or handle them with a fallback.
  """
  def families, do: @families

  @doc false
  # Split out so the check against `priv/static/ithibati.js` can be exact, not a subset.
  def browser_codes, do: Enum.sort(@browser)
end
