defmodule Ithibati.Identity.Secrets do
  @moduledoc false

  # How this library handles a secret, in one place because it is one contract: what the holder is
  # given is URL-safe text, and what the row keeps is its sha256. Three modules store secrets —
  # tokens, recovery codes, and whatever joins them — and a change here that reached only two of
  # them would not fail: it would produce rows that stop matching, which reads to the person holding
  # a correct code as "that is not your code".

  @doc "What goes in the row: a secret this library can compare against but not recover."
  def digest(secret), do: :crypto.hash(:sha256, secret)

  @doc """
  What goes to the holder, for a secret that travels in a header, a cookie or a URL.

  Unpadded, because `=` is punctuation in all three.
  """
  def url64(bytes), do: Base.url_encode64(bytes, padding: false)
end
