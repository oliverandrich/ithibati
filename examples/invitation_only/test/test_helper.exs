ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IthibatiInvites.Repo, :manual)

Application.put_env(:phoenix_test, :base_url, IthibatiInvitesWeb.Endpoint.url())
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
