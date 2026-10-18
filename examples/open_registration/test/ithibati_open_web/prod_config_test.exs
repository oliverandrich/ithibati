defmodule IthibatiOpenWeb.ProdConfigTest do
  @moduledoc """
  Production redirects HTTP to HTTPS, so the session cookie never travels in clear text.
  """
  use ExUnit.Case, async: true

  test "production forces HTTPS with HSTS, behind a TLS-terminating proxy as well" do
    endpoint =
      "config/prod.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:ithibati_open, IthibatiOpenWeb.Endpoint])

    assert endpoint[:force_ssl][:hsts] == true
    assert endpoint[:force_ssl][:rewrite_on] == [:x_forwarded_proto]
  end
end
