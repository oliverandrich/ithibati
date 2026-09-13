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

// `toJSON` is what decision 7 in docs/design.md settles on: the verifications take exactly what it
// produces, so there is no encoding left for a consumer to get wrong. It arrived in Chrome 128 and
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

// Keyed by the name the colocated manifest uses, which LiveView builds as `<module>.<hook name>`.
// A shorter key here would mean `phx-hook` had to say something different depending on which route
// a consumer took, and the one that did not match would fail by doing nothing at all.
export const PasskeyCeremony = {
  mounted() {
    this.handleEvent("ithibati:register", async ({options, reply}) => {
      this.pushEvent(reply, await register(options))
    })

    this.handleEvent("ithibati:authenticate", async ({options, reply}) => {
      this.pushEvent(reply, await authenticate(options))
    })
  }
}

export const hooks = {"Ithibati.Web.Hooks.PasskeyCeremony": PasskeyCeremony}

export default hooks
