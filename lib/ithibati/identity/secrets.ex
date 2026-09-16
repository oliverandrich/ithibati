defmodule Ithibati.Identity.Secrets do
  @moduledoc false

  # How this library handles a secret, in one place because it is one contract: what the holder is
  # given is URL-safe text, and what the row keeps is its sha256. Three modules store secrets —
  # tokens, recovery codes, and whatever joins them — and a change here that reached only two of
  # them would not fail: it would produce rows that stop matching, which reads to the person holding
  # a correct code as "that is not your code".

  @doc "The digest the row keeps: Ithibati can compare a secret against it but cannot recover it."
  def digest(secret), do: :crypto.hash(:sha256, secret)

  @doc """
  Encodes a secret for the holder, for one that travels in a header, a cookie or a URL.

  The encoding is unpadded, because `=` is punctuation in all three.
  """
  def url64(bytes), do: Base.url_encode64(bytes, padding: false)

  @bytes 32

  @doc """
  A fresh secret, ready to hand over: #{@bytes} random bytes as URL-safe text.

  The length lives here, not at each caller, for the reason the module exists. A token and an
  invitation link are the same kind of secret, and a library that mints them at two lengths has made
  a decision nobody took.
  """
  def token, do: @bytes |> :crypto.strong_rand_bytes() |> url64()
end
