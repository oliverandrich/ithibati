ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IthibatiOpen.Repo, :manual)

Application.put_env(:phoenix_test, :base_url, IthibatiOpenWeb.Endpoint.url())
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
