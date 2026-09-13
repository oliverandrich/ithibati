import {defineConfig, devices} from "@playwright/test"

import {EXAMPLES, PARTITION} from "./examples.js"

// `ecto.reset` before every run rather than cleaning up afterwards: a run that crashed half way
// through leaves rows behind, and the first thing an instance-claiming test needs is an instance
// nobody has claimed. No `--quiet`: Mix hands alias arguments to the last task only, so it would
// reach `run priv/repo/seeds.exs` and quieten nothing.
function server({name, port}) {
  return {
    cwd: `../examples/${name}`,
    env: {MIX_ENV: "test", MIX_TEST_PARTITION: PARTITION, PORT: String(port)},
    // `PHX_SERVER` stays inline rather than joining `env`, and that is why these are two commands
    // rather than one: `ecto.reset` ends in `run priv/repo/seeds.exs`, which starts the application
    // — with the variable set it would bind the port, and the server would then fail to.
    command: `mix ecto.reset && PHX_SERVER=true mix phx.server`,
    url: `http://localhost:${port}/`,
    reuseExistingServer: !process.env.CI,
    stdout: "pipe",
    stderr: "pipe",
    timeout: 180_000
  }
}

export default defineConfig({
  testDir: "./tests",

  // The ceremonies write to a shared database per example and several of them are about "the first
  // account" or "this instance is now claimed", which is global state by definition. Workers would
  // race on it, and the failure would look like flakiness rather than like what it is.
  workers: 1,
  fullyParallel: false,

  // A test that only passes on the second attempt is a test nobody can trust; a browser suite is
  // where that habit starts.
  retries: 0,
  forbidOnly: !!process.env.CI,

  // The invitation tests truncate their database first, and that shells out to `mix run`, which
  // boots an application. Playwright counts a `beforeEach` against the test's budget, so the
  // default 30 s would leave two full WebAuthn ceremonies sharing what a BEAM start left over —
  // on a slow runner that is a red build whose timeout points at the last locator instead.
  timeout: 90_000,

  reporter: process.env.CI ? [["html"], ["list"]] : [["list"]],

  use: {
    trace: "retain-on-failure",
    screenshot: "only-on-failure"
  },

  // Chromium only, and not by preference: these tests need a virtual authenticator, and the one
  // that works here is Chrome DevTools Protocol's. `README.md` in this directory carries the
  // measurement. A webkit project left here would be a row that can never be green.
  projects: [{name: "chromium", use: {...devices["Desktop Chrome"]}}],

  webServer: EXAMPLES.map(server)
})
