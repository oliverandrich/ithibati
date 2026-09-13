import {execFileSync} from "node:child_process"

import {test as base, expect} from "@playwright/test"

import {PARTITION, repo, url} from "./examples.js"

export const OPEN = url("open_registration")
export const INVITES = url("invitation_only")

// Chrome DevTools Protocol rather than Playwright's own `browserContext.credentials`, which cannot
// serve this library: its authenticator hands the page a synthetic credential whose `toJSON()` —
// what this library serialises with — comes back empty. `README.md` in this directory has the
// measurement. CDP's authenticator lives inside Chrome's own WebAuthn implementation, so the page
// receives a genuine credential; the cost is that it is Chromium-only.
async function virtualAuthenticator(context, page) {
  const cdp = await context.newCDPSession(page)

  await cdp.send("WebAuthn.enable", {enableUI: false})

  const {authenticatorId} = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      ctap2Version: "ctap2_1",
      // `internal` is a platform authenticator — Touch ID, Windows Hello — which is what a passkey
      // for a web application actually is.
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true
    }
  })

  return {
    // Every credential the *page* registered. Nothing is ever seeded: a credential this file minted
    // would prove that CDP can mint one, where the question is whether the ceremony can.
    async credentials() {
      const {credentials} = await cdp.send("WebAuthn.getCredentials", {authenticatorId})

      return credentials
    }
  }
}

export const test = base.extend({
  // Automatic: every test here drives a page that can start a ceremony, and a test that forgets to
  // ask for it would meet the platform's own WebAuthn instead — which in headless Chrome fails with
  // an error the hook reports as `ceremony_failed`, three steps away from the cause. Tests that
  // question the authenticator still name it in their arguments.
  authenticator: [
    async ({context, page}, use) => {
      await use(await virtualAuthenticator(context, page))
    },
    {auto: true}
  ],

  // The one thing no amount of clicking produces: a dialog the person dismissed. WebAuthn reports
  // that as a `NotAllowedError`, and turning it into `ceremony_cancelled` rather than into a
  // failure that names the server is the hook's job.
  dismissPrompt: async ({context}, use) => {
    await use(async () => {
      await context.addInitScript(() => {
        const refuse = () => {
          const error = new Error("The operation either timed out or was not allowed.")
          error.name = "NotAllowedError"

          return Promise.reject(error)
        }

        navigator.credentials.create = refuse
        navigator.credentials.get = refuse
      })
    })
  }
})

// A name no other test in this run has used. The suite keeps one database per example for the whole
// run — resetting between tests costs a BEAM boot each — so tests stay out of each other's way by
// naming rather than by cleaning up. It also survives `reuseExistingServer`, which means a second
// local run does not meet the first run's rows.
export function aUsername(prefix) {
  return `${prefix}_${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`
}

// Whoever claims an instance claims it for good, so the tests about *that* cannot name their way
// around each other — the row they contend for is the point. Truncating is enough and, unlike
// `ecto.reset`, does not have to evict the running server's connections first. Run through the
// example's own `mix` so the credentials and the database name come from its config rather than
// from a second copy here.
export function truncate(example) {
  const query =
    "DO $$ DECLARE r record; BEGIN " +
    "FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' " +
    "AND tablename <> 'schema_migrations' LOOP " +
    "EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' RESTART IDENTITY CASCADE'; " +
    "END LOOP; END $$;"

  // The application starts, so the repo is supervised the way it is in the running server; nothing
  // listens, because `PHX_SERVER` is what decides that and this call does not set it.
  execFileSync(
    "mix",
    ["run", "-e", `Ecto.Adapters.SQL.query!(${repo(example)}, ${JSON.stringify(query)})`],
    {
      cwd: `../examples/${example}`,
      env: {...process.env, MIX_ENV: "test", MIX_TEST_PARTITION: PARTITION},
      stdio: "pipe"
    }
  )
}

export {expect}
