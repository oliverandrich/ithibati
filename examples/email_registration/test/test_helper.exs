ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IthibatiEmail.Repo, :manual)

Application.put_env(:phoenix_test, :base_url, IthibatiEmailWeb.Endpoint.url())
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
