defmodule Ithibati do
  @moduledoc """
  Passkey authentication: the account row, its WebAuthn credentials, its recovery codes and its
  revocable tokens.

  What an account may *do* — roles, tenancy, memberships — is the consuming application's, and this
  library is built so that it stays there. An invitation is the one thing that sits on the line: whom
  it is addressed to is here, what it grants is not. The reasoning is in `docs/design.md`.
  """
end
