defmodule Ithibati.Identity.Secrets do
  @moduledoc false

  # Session and invitation tokens share one encoding and digest contract.

  @doc "The digest the row keeps: Ithibati can compare a secret against it but cannot recover it."
  def digest(secret), do: :crypto.hash(:sha256, secret)

  @doc """
  Encodes bytes as unpadded Base64url text for transport in cookies, headers and URLs.
  """
  def url64(bytes), do: Base.url_encode64(bytes, padding: false)

  @bytes 32

  @doc """
  Generates #{@bytes} cryptographically random bytes and returns unpadded Base64url text.
  """
  def token, do: @bytes |> :crypto.strong_rand_bytes() |> url64()
end
