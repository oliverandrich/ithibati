// Where the two example applications answer, and under which database, in one place: the Playwright
// config starts them from this, and `fixtures.js` navigates to it. Written twice, a changed port
// would leave the tests driving whatever is still listening on the old one — and with
// `reuseExistingServer` on locally, that is a stale server rather than an error.
export const EXAMPLES = [
  {name: "open_registration", port: 4101, repo: "IthibatiOpen.Repo"},
  {name: "invitation_only", port: 4102, repo: "IthibatiInvites.Repo"}
]

const find = (name) => EXAMPLES.find((example) => example.name === name)

export const url = (name) => `http://localhost:${find(name).port}`
export const repo = (name) => find(name).repo

// The generated `config/test.exs` interpolates this into the database name, so the suite lands in
// `*_teste2e`: it cannot collide with `mix test` and never touches a `*_dev` database.
export const PARTITION = "e2e"
