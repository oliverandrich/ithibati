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

  defmodule Ithibati.TestPageController do
    @moduledoc false
    use Phoenix.Controller, formats: [:json]

    alias Ithibati.TestRepo
    alias Ithibati.TestUser
    alias Ithibati.Web.Gate

    # What a consumer's own sign-in controller does after its handler verified an assertion. Here
    # so that a test signs in through a real response, cookie and all: a session built by hand never
    # passes through `Plug.Session`, so nothing would carry to the next request.
    def sign_in(conn, %{"id" => id}) do
      account = TestRepo.get!(TestUser, id)

      conn |> Gate.log_in(account) |> json(%{signed_in: true})
    end

    def sign_out(conn, _params),
      do: conn |> Gate.log_out() |> json(%{signed_out: true})

    # `conn.assigns.current_account`, not `conn.assigns[:current_account]`: every route reaching
    # here went through a gate, so a missing assign is the gate failing to assign — and read with
    # brackets that is indistinguishable from the answer `nil` the open route legitimately gives.
    def show(conn, _params) do
      account = conn.assigns.current_account

      json(conn, %{account_id: account && to_string(account.id)})
    end
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

    # One scope per gate mode, so the modes are exercised through a pipeline rather than by calling
    # the plug: a mode that only works when somebody else fetched the session first would pass a
    # direct call and fail a request.
    pipeline :maybe_account do
      plug(Ithibati.Web.Gate, :current_account)
    end

    pipeline :must_account do
      plug(Ithibati.Web.Gate, {:require_account, to: "/sign-in"})
    end

    pipeline :must_account_api do
      plug(Ithibati.Web.Gate, :require_account)
    end

    scope "/session" do
      pipe_through(:browser)
      get("/out", Ithibati.TestPageController, :sign_out)
      get("/:id", Ithibati.TestPageController, :sign_in)
    end

    scope "/open" do
      pipe_through([:browser, :maybe_account])
      get("/", Ithibati.TestPageController, :show)
    end

    scope "/closed" do
      pipe_through([:browser, :must_account])
      get("/", Ithibati.TestPageController, :show)
    end

    scope "/api" do
      pipe_through([:browser, :must_account_api])
      get("/", Ithibati.TestPageController, :show)
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
