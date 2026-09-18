ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IthibatiEmail.Repo, :manual)

# Wallaby is `runtime: false`, so nothing starts it for us, and it has to be told where the
# application answers and which driver to run.
Application.put_env(:wallaby, :chromedriver,
  path: IthibatiEmailWeb.BrowserDriver.path(),
  headless: true
)

Application.put_env(:wallaby, :base_url, IthibatiEmailWeb.Endpoint.url())
{:ok, _} = Application.ensure_all_started(:wallaby)
