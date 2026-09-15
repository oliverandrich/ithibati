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

    @impl true
    def recovered(conn, account, fresh),
      do: {:ok, conn |> Plug.Conn.assign(:account, account) |> Plug.Conn.assign(:fresh, fresh)}
  end

  # A consumer that serves a client whose origin is not the server's own — an extension, a native
  # app's associated domain. The relying-party id stays the server's; only the origin differs.
  defmodule Ithibati.TestExtensionHandler do
    @moduledoc false

    # Declared before ours on purpose. A handler written on a controller has this one in front,
    # injected by `use Phoenix.Controller`, and `Ithibati.Doctor` has to find ours behind it —
    # `module_info(:attributes)[:behaviour]` answers with the first attribute only.
    @behaviour Plug
    @behaviour Ithibati.Web.Handler

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts), do: conn

    @impl true
    def registration_subject(_conn, _params), do: {:ok, "someone@example.com"}

    @impl true
    def register(conn, _key_attrs, _subject, _params), do: {:ok, conn}

    @impl true
    def authenticate(conn, account), do: {:ok, Plug.Conn.assign(conn, :account, account)}

    @impl true
    def recovered(conn, account, _fresh), do: {:ok, Plug.Conn.assign(conn, :account, account)}

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

  # A handler that answers `recovered/3` with a bare connection instead of `{:ok, conn}`. `@impl`
  # does not catch it — a callback has no compile-time return check — so the mistake is the
  # controller's to make loud. Used by exactly one test.
  defmodule Ithibati.TestSloppyHandler do
    @moduledoc false
    @behaviour Ithibati.Web.Handler

    # Everything but the one wrong answer comes from the handler beside it, so the fixture reads
    # as what it is: `recovered/3` returning a bare connection where `{:ok, conn}` was the
    # contract.
    @impl true
    defdelegate registration_subject(conn, params), to: Ithibati.TestExtensionHandler

    @impl true
    defdelegate register(conn, key_attrs, subject, params), to: Ithibati.TestExtensionHandler

    @impl true
    defdelegate authenticate(conn, account), to: Ithibati.TestExtensionHandler

    @impl true
    def recovered(conn, _account, _fresh), do: conn
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

    # The pipeline `docs/ceremonies.md` asks for, by the same name, because a fixture that wired
    # these routes differently would be this library's own counter-example. `accepts ["json"]` is
    # the half that
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

    scope "/sloppy" do
      pipe_through(:ceremony)
      ithibati_routes(handler: Ithibati.TestSloppyHandler, rp_name: "Ithibati Sloppy")
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

  # So that an exception raised in a request reaches the test as itself, rather than as the
  # failure to render a 500 for it.
  defmodule Ithibati.TestErrorJSON do
    @moduledoc false
    def render(template, _assigns), do: %{error: template}
  end

  defmodule Ithibati.TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ithibati

    plug(Plug.Session, store: :cookie, key: "_ithibati_test", signing_salt: "MJ1tPqEr")
    plug(Ithibati.TestRouter)
  end

  # The other kind of consumer: Phoenix with no `pubsub_server`. It exists so that the branch which
  # leaves such an application alone has something to answer for — `log_in/2` must write no socket
  # id there, because one written would take every websocket down at connect, not merely fail to
  # disconnect.
  #
  # No plugs, because nothing is ever dispatched through it: the tests reach it by naming it on a
  # connection, and all they ask is what it has configured. Giving it a pipeline would present a
  # second working consumer that nothing has ever run.
  defmodule Ithibati.TestEndpointWithoutPubSub do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ithibati
  end
end
