// The client half of the passkey ceremonies: the encoding the browser's API needs on the way in,
// and the shape this library expects back on the way out.
//
// One file, two ways to reach it. A consumer imports it by path out of `deps/`, or imports
// `phoenix-colocated/ithibati`, whose hook re-exports from here rather than carrying a second copy.
// Both register the same name, so a template written for one works under the other.

// `wax_` is handed unpadded base64url and this library hands the browser the same, because that is
// what WebAuthn specifies. `atob` speaks the other alphabet, which is the whole of the difference:
// it accepts unpadded input, and the one remainder it rejects cannot arise from encoding bytes.
function fromBase64url(value) {
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from(binary, (c) => c.charCodeAt(0)).buffer
}

// The two dictionaries below each carry a list of credential descriptors, under different names and
// with different meanings, but with the same encoded id.
function decodeCredentialIds(descriptors) {
  return descriptors.map((c) => ({...c, id: fromBase64url(c.id)}))
}

// The fields the server sends base64url-encoded, which `navigator.credentials` wants as buffers.
// Named rather than walked generically: a generic walk would also convert a future string field
// that is meant to stay a string, and the failure would be a ceremony the authenticator refuses
// for no visible reason.
function decodeCreationOptions(options) {
  const decoded = {...options, challenge: fromBase64url(options.challenge)}
  decoded.user = {...options.user, id: fromBase64url(options.user.id)}

  if (options.excludeCredentials) {
    decoded.excludeCredentials = decodeCredentialIds(options.excludeCredentials)
  }

  return decoded
}

function decodeRequestOptions(options) {
  const decoded = {...options, challenge: fromBase64url(options.challenge)}

  if (options.allowCredentials) {
    decoded.allowCredentials = decodeCredentialIds(options.allowCredentials)
  }

  return decoded
}

// The verifications take exactly what `toJSON` produces, so there is no encoding left for a
// consumer to get wrong. It arrived in Chrome 128 and
// Safari 18; anything older raises here rather than posting a body the server cannot read.
function serialise(credential) {
  if (typeof credential.toJSON !== "function") {
    throw new Error(
      "This browser's PublicKeyCredential has no toJSON(); Ithibati needs one to post a credential."
    )
  }

  return credential.toJSON()
}

export async function register(options) {
  return serialise(await navigator.credentials.create({publicKey: decodeCreationOptions(options)}))
}

export async function authenticate(options) {
  return serialise(await navigator.credentials.get({publicKey: decodeRequestOptions(options)}))
}

// The transport is the controller, not the LiveView channel, and that is not a detail: only a
// controller can set a session cookie. So a LiveView says when to start — it has the identity
// fields and has already validated them — and everything after that is `fetch`.
async function post(url, body) {
  // Just JSON, deliberately. Adding `*/*` would make a `:browser` pipeline negotiate silently to
  // HTML and hand this code error pages it cannot read; refusing outright gives a 406 that names
  // the mistake. `docs/ceremonies.md` asks for a pipeline that accepts `json` for exactly this
  // reason, and a 406 is how that instruction was found to be missing in the first place.
  const headers = {"content-type": "application/json", accept: "application/json"}

  // `protect_from_forgery` guards everything that is not a GET and reads the token from this
  // header or from a `_csrf_token` field — a JSON body is not exempt from it.
  const token = document.querySelector("meta[name='csrf-token']")?.content
  if (token) headers["x-csrf-token"] = token

  const response = await fetch(url, {
    method: "POST",
    headers,
    // The cookie the sign-in is about to set is the whole point of this request.
    credentials: "same-origin",
    body: JSON.stringify(body)
  })

  // A proxy's error page, a redirect to a sign-in, a 500: parsing those throws a SyntaxError that
  // is indistinguishable from a cancelled ceremony by the time it is caught.
  const parsed = await response.json().catch(() => ({}))

  return {ok: response.ok, status: response.status, body: parsed}
}

// One place that says which ceremony is which. The alternative is a two-valued discriminator
// spelled out at each of three sites, two of them ternaries, which fail by quietly taking the
// other branch.
const CEREMONIES = {
  registration: {start: register},
  authentication: {start: authenticate}
}

export const PasskeyCeremony = {
  mounted() {
    this.handleEvent("ithibati:register", (identity) => this.run("registration", identity))
    this.handleEvent("ithibati:authenticate", () => this.run("authentication", {}))
    this.handleEvent("ithibati:recover", (payload) => this.recover(payload))
  },

  // One request and no authenticator: a recovery code is typed, not signed. It goes through the
  // hook anyway because the endpoint answers JSON and sets a session cookie, which is a `fetch`
  // from a page rather than anything a LiveView can do.
  async recover({code}) {
    try {
      const answer = await post(this.requiredUrl("recovery-url"), {code})
      if (!answer.ok) return this.failed(answer.body.error, answer.status)

      this.done(answer.body)
    } catch (error) {
      if (error.name === "IthibatiMissingUrl") return this.failed(error.message)

      this.failed("recovery_failed")
    }
  },

  async run(ceremony, identity) {
    try {
      const challengeUrl = this.requiredUrl(`${ceremony}-challenge-url`)
      const verifyUrl = this.requiredUrl(`${ceremony}-url`)

      const started = await post(challengeUrl, identity)
      if (!started.ok) return this.failed(started.body.error, started.status)

      const credential = await CEREMONIES[ceremony].start(started.body)

      const finished = await post(verifyUrl, {...identity, credential})
      if (!finished.ok) return this.failed(finished.body.error, finished.status)

      this.done(finished.body)
    } catch (error) {
      // A cancelled or failed ceremony is a `DOMException`, which the server never hears about —
      // the person closed the dialog. A missing URL is the one reported by name, because it is a
      // wiring mistake and looks exactly like a cancelled ceremony otherwise.
      if (error.name === "IthibatiMissingUrl") return this.failed(error.message)

      this.failed(error.name === "NotAllowedError" ? "ceremony_cancelled" : "ceremony_failed")
    }
  },

  // A handler that answered with somewhere to go is obeyed; anything else is the page's to
  // decide, so it goes back to the LiveView rather than being acted on here.
  done(body) {
    if (body.redirect) {
      window.location.href = body.redirect
    } else {
      this.pushEvent("ithibati:done", body)
    }
  },

  // Read by the attribute's own spelling rather than through `dataset`, so the name the error
  // reports and the name that was looked up cannot come apart.
  requiredUrl(attribute) {
    const value = this.el.getAttribute(`data-${attribute}`)
    if (value) return value

    const error = new Error(`missing_data_${attribute.replace(/-/g, "_")}`)
    error.name = "IthibatiMissingUrl"
    throw error
  },

  // A refusal this library produced names itself in the body. Anything else — a pipeline that
  // rejected the request before the controller, a proxy, a crash — has no body to name, and
  // reporting "unknown" there tells nobody anything: the status is the only thing that does.
  failed(error, status) {
    const reason = error || (status ? `http_${status}` : "unknown")

    this.pushEvent("ithibati:failed", {error: reason, status: status || null})
  }
}

// Keyed by the name the colocated manifest uses, which LiveView builds as `<module>.<hook name>`.
// A shorter key here would mean `phx-hook` had to say something different depending on which route
// a consumer took, and the one that did not match would fail by doing nothing at all.
export const hooks = {"Ithibati.Web.Hooks.PasskeyCeremony": PasskeyCeremony}

export default hooks
