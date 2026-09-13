# Guarded like the modules it exercises: `test/support` is on `elixirc_paths(:test)`, so without
# this the build that proves the core compiles without Phoenix would fail here instead.
if Code.ensure_loaded?(Phoenix.Component) do
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

  # A consumer that serves a client whose origin is not the server's own — an extension, a native
  # app's associated domain. The relying-party id stays the server's; only the origin differs.
  defmodule Ithibati.TestExtensionHandler do
    @moduledoc false
    @behaviour Ithibati.Web.Handler

    @impl true
    def registration_subject(_conn, _params), do: {:ok, "someone@example.com"}

    @impl true
    def register(conn, _key_attrs, _subject, _params), do: {:ok, conn}

    @impl true
    def authenticate(conn, account), do: {:ok, Plug.Conn.assign(conn, :account, account)}

    # The relying-party id stays the server's domain — an extension may name any domain in its
    # `host_permissions`, so it does not become its own relying party. The origins are a list
    # because the same extension has a different stable one in each browser.
    @extensions [
      "chrome-extension://mabekielmoibbmlepeohhncklpnjmcpk",
      "moz-extension://ngpncaopklanhjklijieoihgbhbgknjjdklmlpagjoaobbpmknfgmhgghbadgoai"
    ]

    @impl true
    def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extensions]}
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

    # The pipeline the README asks for, by the same name, because a fixture that wired these routes
    # differently would be this library's own counter-example. `accepts ["json"]` is the half that
    # matters: a `:browser` pipeline refuses the hook's request with a 406 before the controller is
    # reached. `fetch_session` is the other — the endpoints call `put_session/3`, which raises
    # unless something fetched one, and a test that installs a session by hand cannot notice that
    # the documented wiring never did.
    pipeline :ceremony do
      plug(:accepts, ["json"])
      plug(:fetch_session)
    end

    # What the gate's own routes need, which is a session and nothing of the ceremony's. Named
    # apart from `:ceremony` so that neither pipeline's comment has to explain the other's routes.
    pipeline :session do
      plug(:accepts, ["json"])
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
      pipe_through(:session)
      get("/out", Ithibati.TestPageController, :sign_out)
      get("/:id", Ithibati.TestPageController, :sign_in)
    end

    scope "/open" do
      pipe_through([:session, :maybe_account])
      get("/", Ithibati.TestPageController, :show)
    end

    scope "/closed" do
      pipe_through([:session, :must_account])
      get("/", Ithibati.TestPageController, :show)
    end

    scope "/api" do
      pipe_through([:session, :must_account_api])
      get("/", Ithibati.TestPageController, :show)
    end

    scope "/auth" do
      pipe_through(:ceremony)
      ithibati_routes(handler: Ithibati.TestHandler, rp_name: "Ithibati Test")
    end

    scope "/extension" do
      pipe_through(:ceremony)
      ithibati_routes(handler: Ithibati.TestExtensionHandler, rp_name: "Ithibati Extension")
    end

    # A second mount, so the ceremony options can be shown to come from the macro rather than from
    # a default that happens to match — two mounts answering to different rules is the reason they
    # are recorded on the routes instead of in application configuration.
    scope "/strict" do
      pipe_through(:ceremony)

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
