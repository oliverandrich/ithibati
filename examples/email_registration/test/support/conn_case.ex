defmodule IthibatiEmailWeb.ConnCase do
  @moduledoc "Request tests share the configured endpoint and a sandboxed database connection."

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint IthibatiEmailWeb.Endpoint

      use IthibatiEmailWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import IthibatiEmailWeb.ConnCase
    end
  end

  setup tags do
    IthibatiEmail.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
