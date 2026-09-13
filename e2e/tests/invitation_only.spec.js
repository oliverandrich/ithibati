import {test, expect, truncate, INVITES} from "../fixtures.js"

// Every test here is about the row an instance can hold exactly once — a claim, an invitation that
// is spent by being accepted. Unique names cannot separate those the way they separate the open
// example's accounts, because the contention *is* the subject. So each starts from an empty
// database.
test.beforeEach(() => truncate("invitation_only"))

test.describe("invitation only", () => {
  // Two preludes the first test walks through with its own assertions, so that the tests *about*
  // something else can reach their subject in a line. Deliberately not used by the first test: what
  // it exists to show is every step of the flow, and folding those into a call would hide it.
  async function claim(page, username) {
    await page.goto(`${INVITES}/`)
    await page.getByRole("textbox").fill(username)
    await page.getByRole("button", {name: "Claim this instance"}).click()
    await page.waitForURL("**/recovery-codes")
  }

  // The link is shown once and never again — the row holds the token's digest — so it is read here
  // or not at all.
  async function inviteLink(page, username) {
    await page.goto(`${INVITES}/inside`)
    await page.getByRole("textbox").fill(username)
    await page.getByRole("button", {name: "Create a link"}).click()

    return (await page.locator("code").first().innerText()).trim()
  }

  test("the first account claims the instance, and everyone after it arrives on a link", async ({
    page,
    context
  }) => {
    await page.goto(`${INVITES}/`)

    await expect(page.getByText("Nobody has claimed this instance yet")).toBeVisible()
    await page.getByRole("textbox").fill("ada")
    await page.getByRole("button", {name: "Claim this instance"}).click()
    await page.waitForURL("**/recovery-codes")

    await page.goto(`${INVITES}/inside`)
    await page.getByRole("textbox").fill("grace")
    await page.getByRole("button", {name: "Create a link"}).click()

    // Shown once and never again: the row holds the token's digest, so nothing can render it a
    // second time. That is why the test has to read it here rather than looking it up later.
    const link = (await page.locator("code").first().innerText()).trim()
    expect(link).toContain("/invite/")

    // A fresh session, because an invitation is for somebody who is not signed in.
    await context.clearCookies()
    await page.goto(link)

    // The page names the account it will create and offers no field to change it — the refusal
    // `Invitations.accept/2` would give is turned into an interface that cannot ask for it.
    await expect(page.getByText("The account will be called")).toBeVisible()
    await expect(page.locator("main input")).toHaveCount(0)

    await page.getByRole("button", {name: "Accept with a passkey"}).click()
    await page.waitForURL("**/recovery-codes")

    await page.goto(`${INVITES}/inside`)
    await expect(page.getByText("Signed in as grace.")).toBeVisible()
  })

  test("a spent link and an invented one are answered exactly alike", async ({page, context}) => {
    await claim(page, "ada")
    const link = await inviteLink(page, "grace")

    await context.clearCookies()
    await page.goto(link)
    await page.getByRole("button", {name: "Accept with a passkey"}).click()
    await page.waitForURL("**/recovery-codes")

    await context.clearCookies()
    await page.goto(link)
    const spent = await page.locator("main").innerText()

    await page.goto(`${INVITES}/invite/a-token-nobody-ever-held`)
    const invented = await page.locator("main").innerText()

    // Byte for byte, because anything else tells a guesser which of their guesses was once real.
    expect(spent).toBe(invented)
    expect(spent).toContain("has been used already, or it has expired")
  })

  test("the instance can be claimed once, and the form does not come back", async ({page}) => {
    await claim(page, "ada")

    await page.goto(`${INVITES}/`)
    await expect(page.getByText("Registration is by invitation")).toBeVisible()
    await expect(page.locator("main input")).toHaveCount(0)
  })
})
