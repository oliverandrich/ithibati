defmodule Ithibati.Ceremony do
  @moduledoc """
  Every code a ceremony can fail with that came from this library.

  A refusal reaches your page as `ithibati:failed` carrying a code as a string, and turning that
  into a sentence is yours. What this module answers is the prior question: which codes are there
  to answer for. Both halves produce them, and a page cannot tell which half a code came from.

      test "every code the library can send has a sentence" do
        for code <- Ithibati.Ceremony.codes() do
          refute message(to_string(code)) =~ "Something went wrong"
        end
      end

  That goes red when a release adds a word, which is the day to decide what your page says.

  It does not cover the two families `families/0` names, nor your handler's own refusals:
  `Ithibati.Web.PasskeyController` passes any atom a callback returns straight through, so the set
  that arrives is open and this one is not.

  `docs/ceremonies.md` explains each code.
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
  The two codes that carry a suffix, as prefixes.

  `:http` becomes `http_404` from the status an endpoint answered with, and `:missing_data`
  becomes `missing_data_registration_url` from the attribute the hook element is missing. Neither
  can be listed, so match on the prefix or leave them to a catch-all.
  """
  def families, do: @families

  @doc false
  # Split out so the check against `priv/static/ithibati.js` can be exact, not a subset.
  def browser_codes, do: Enum.sort(@browser)
end
