# Guarded like the modules it exercises: `test/support` is on `elixirc_paths(:test)`, so without
# this the build that proves the core compiles without Phoenix would fail here instead.
if Code.ensure_loaded?(Phoenix.Router) do
  defmodule Ithibati.TestHandler do
    @moduledoc false
    @behaviour Ithibati.Web.Handler

    @impl true
    def registration_subject(_conn, %{"identifier" => identifier}), do: {:ok, identifier}

    def registration_subject(_conn, _params), do: {:error, :no_identifier}

    @impl true
    def register(conn, key_attrs, subject, _params) do
      {:ok,
       conn |> Plug.Conn.assign(:key_attrs, key_attrs) |> Plug.Conn.assign(:subject, subject)}
    end

    @impl true
    def authenticate(conn, account), do: {:ok, Plug.Conn.assign(conn, :account, account)}
  end

  defmodule Ithibati.TestRouter do
    @moduledoc false
    use Phoenix.Router
    import Ithibati.Web.Router

    # What a consumer's own router looks like, session plug and all, rather than a bare scope: the
    # endpoints call `put_session/3`, which raises unless something fetched the session first, and a
    # test that installs one by hand cannot notice that the documented wiring never did.
    pipeline :browser do
      plug(:fetch_session)
    end

    scope "/auth" do
      pipe_through(:browser)
      ithibati_routes(handler: Ithibati.TestHandler, rp_name: "Ithibati Test")
    end

    # A second mount, so the ceremony options can be shown to come from the macro rather than from
    # a default that happens to match — two mounts answering to different rules is the reason they
    # are recorded on the routes instead of in application configuration.
    scope "/strict" do
      pipe_through(:browser)

      ithibati_routes(
        handler: Ithibati.TestHandler,
        rp_name: "Ithibati Strict",
        user_verification: "required",
        seconds: 30
      )
    end
  end

  defmodule Ithibati.TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ithibati

    plug(Plug.Session, store: :cookie, key: "_ithibati_test", signing_salt: "MJ1tPqEr")
    plug(Ithibati.TestRouter)
  end
end
