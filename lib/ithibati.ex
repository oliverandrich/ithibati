defmodule Ithibati do
  @moduledoc """
  Passkey authentication: the account row, its WebAuthn credentials, its recovery codes and the
  sessions it is signed in with.

  What an account may *do* belongs to the application: roles, tenancy, memberships. Ithibati is
  built so that it stays there. An invitation sits on the line between the two. Ithibati holds whom
  an invitation is addressed to. The application holds what it grants.
  """
end
