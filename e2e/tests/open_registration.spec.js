import {test, expect, aUsername, OPEN} from "../fixtures.js"

// Everything here goes through `priv/static/ithibati.js` as the example's esbuild bundled it, so a
// green run says the shipped client code works — not that a copy of it does.
test.describe("open registration", () => {
  test("a passkey is made, the codes are shown once, and the same passkey signs back in", async ({
    page,
    authenticator
  }) => {
    const username = aUsername("ada")

    await page.goto(`${OPEN}/`)
    await page.getByRole("textbox").fill(username)
    await page.getByRole("button", {name: "Register"}).click()

    // The handler answers `%{redirect: "/recovery-codes"}` and the hook acts on it with a full page
    // load, which a sign-in needs anyway: renewing the session takes the CSRF token with it.
    await page.waitForURL("**/recovery-codes")
    await expect(page.getByRole("heading", {name: "Your recovery codes"})).toBeVisible()
    // Scoped to `main`: the navigation is a list too, and a bare count would be asserting the
    // layout as much as the codes.
    await expect(page.locator("main li")).toHaveCount(12)

    // The authenticator now holds a credential the *page* registered — proof the ceremony reached
    // `navigator.credentials.create` rather than being simulated around it.
    expect(await authenticator.credentials()).toHaveLength(1)

    // Behind `{:require_account, to: "/"}`, so reaching it at all is the gate answering.
    await page.goto(`${OPEN}/inside`)
    await expect(page.getByText(`Only ${username} sees this.`)).toBeVisible()

    await page.goto(`${OPEN}/`)
    await page.getByRole("link", {name: "sign out"}).click()
    await expect(page.getByText("Signed in as")).toHaveCount(0)

    // Usernameless: the sign-in names no credential at all, so this only works because the
    // credential is discoverable — the property `registration_options/3` refuses to leave to the
    // authenticator's discretion.
    await page.getByRole("button", {name: "Sign in with a passkey"}).click()
    await expect(page.getByText(`Signed in as ${username}`)).toBeVisible()
  })

  // The server-side refusal is pinned in `test/ithibati_open/auth_test.exs`, and it cannot also be
  // driven from here: the `pattern` attribute is derived from the same regex the server validates
  // with, so the browser refuses everything the server would. That agreement is the subject of this
  // test — what it proves is that the derived attribute reached the DOM and is doing its job, which
  // no Elixir test can see.
  test("a name the server would refuse never leaves the browser", async ({page, authenticator}) => {
    await page.goto(`${OPEN}/`)

    // What the form would send if it submitted, counted rather than inferred: asserting that the
    // page did not navigate proves nothing, because it has not navigated yet either way, and
    // reading the authenticator microseconds after the click is too early for a ceremony that did
    // start to have reached it.
    const challenges = []
    page.on("request", (request) => {
      if (request.url().endsWith("/auth/registration/challenge")) challenges.push(request.url())
    })

    const field = page.getByRole("textbox")
    await field.fill("Ada Lovelace!")

    expect(await field.evaluate((el) => el.checkValidity())).toBe(false)

    await page.getByRole("button", {name: "Register"}).click()

    // Long enough that a round trip would have happened. Nothing was minted, so nobody is left
    // holding a passkey for an account that does not exist.
    await page.waitForTimeout(1000)
    expect(challenges).toHaveLength(0)
    expect(await authenticator.credentials()).toHaveLength(0)
  })
})
