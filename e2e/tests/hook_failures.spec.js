import {test, expect, aUsername, OPEN} from "../fixtures.js"

// The half of the hook nobody had ever watched fail. Each of these is a different branch of the
// `catch` in `run/2`, and each reports a different reason — a library that collapsed them would hand
// a consumer "something went wrong" for a wiring mistake they could have fixed in a second.
//
// None of it needs test-only code in the example: the wiring lives in data attributes and the dialog
// lives in `navigator.credentials`, so a test can spoil either from the outside.
test.describe("what the hook reports when a ceremony does not finish", () => {
  // Setting the value instead of `fill()`, because `fill()` dispatches the `input` event that
  // `phx-change="validate"` listens for — and the patch that comes back restores every `data-`
  // attribute in the template, including the one the test just spoiled. The patch lands
  // asynchronously, so ordering the two calls is a race rather than a fix; not starting the round
  // trip at all is the fix. `phx-submit` serialises the form from the DOM, so the server still
  // receives what was typed.
  async function type(page, value) {
    await page.getByRole("textbox").evaluate((el, value) => (el.value = value), value)
  }

  async function spoil(page, attribute, value) {
    await page.locator("#passkey").evaluate(
      (el, {attribute, value}) =>
        value === null ? el.removeAttribute(attribute) : el.setAttribute(attribute, value),
      {attribute, value}
    )

    // Retrying, and read back from the page rather than assumed: these tests are about what the
    // hook does when the element is wrong, and an element that is quietly right tests nothing.
    // Absence and a value are different assertions — a removed attribute reads as `null`, which no
    // value ever matches.
    const element = page.locator("#passkey")

    if (value === null) {
      await expect(element).not.toHaveAttribute(attribute, {timeout: 2000})
    } else {
      await expect(element).toHaveAttribute(attribute, value, {timeout: 2000})
    }
  }

  test("a missing data attribute is named, not reported as a failed ceremony", async ({page}) => {
    await page.goto(`${OPEN}/`)
    await type(page, aUsername("ada"))
    await spoil(page, "data-registration-url", null)

    await page.getByRole("button", {name: "Register"}).click()

    // The attribute's own spelling, so the message says which one to go and add. Reported by name
    // because a wiring mistake otherwise looks exactly like somebody dismissing the dialog.
    await expect(page.getByText("missing_data_registration_url")).toBeVisible()
  })

  test("a response that is not JSON reports its status rather than nothing at all", async ({
    page
  }) => {
    await page.goto(`${OPEN}/`)
    await type(page, aUsername("ada"))

    // A 404 whose body is an HTML error page: `response.json()` throws, the body becomes `{}`, and
    // there is no `error` key to report. Answering "unknown" there is what this actually did once,
    // and it told nobody anything — the status is the only thing that does.
    await spoil(page, "data-registration-challenge-url", "/no-such-route")

    await page.getByRole("button", {name: "Register"}).click()

    await expect(page.getByText("http_404")).toBeVisible()
    await expect(page.getByText("unknown")).toHaveCount(0)
  })

  test("a dismissed prompt is reported as cancelled, and no account is left behind", async ({
    page,
    authenticator,
    dismissPrompt
  }) => {
    await dismissPrompt()
    await page.goto(`${OPEN}/`)

    await page.getByRole("textbox").fill(aUsername("ada"))
    await page.getByRole("button", {name: "Register"}).click()

    await expect(page.getByText("The passkey prompt was dismissed.")).toBeVisible()
    expect(await authenticator.credentials()).toHaveLength(0)

    // The challenge was spent by the attempt, but nothing else was: the person is still on the page,
    // still nobody, and free to try again.
    await expect(page).toHaveURL(`${OPEN}/`)
  })

  test("a refusal the server named is shown as the server's own reason", async ({
    page
  }) => {
    const username = aUsername("ada")

    await page.goto(`${OPEN}/`)
    await page.getByRole("textbox").fill(username)
    await page.getByRole("button", {name: "Register"}).click()
    await page.waitForURL("**/recovery-codes")

    // A second registration for a name that now exists. The reason travels from the handler through
    // the JSON body, the hook and `ithibati:failed` into a sentence — the chain the README describes
    // and nothing executed until now.
    await page.goto(`${OPEN}/`)
    await page.getByRole("textbox").fill(username)
    await page.getByRole("button", {name: "Register"}).click()

    await expect(page.getByText("That username is taken.")).toBeVisible()
  })
})
