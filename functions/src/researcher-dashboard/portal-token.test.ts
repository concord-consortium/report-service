import jwt from "jsonwebtoken"
import { generateKeyPairSync, createHmac } from "crypto"
import { execFileSync } from "child_process"
import { parsePortalKeys, verifyPortalToken, PortalTokenError, PortalKeys } from "./portal-token"

const AUDIENCE = "report-service-functions"

const makeKey = (kid: string, iss: string) => {
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 })
  return {
    kid,
    iss,
    publicPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
    privatePem: privateKey.export({ type: "pkcs8", format: "pem" }).toString()
  }
}

const staging = makeKey("staging-test", "https://learn.portal.staging.concord.org/")
const production = makeKey("production-test", "https://learn.concord.org/")

const keysJson = JSON.stringify([staging, production].map(k => ({ kid: k.kid, iss: k.iss, pem: k.publicPem })))
const keys: PortalKeys = parsePortalKeys(keysJson)

const now = () => Math.floor(Date.now() / 1000)
const claims = (overrides: Record<string, unknown> = {}) =>
  ({ iss: staging.iss, aud: AUDIENCE, uid: 42, iat: now(), exp: now() + 120, ...overrides })

// kid null signs with no kid in the header
const sign = (payload: object, key = staging, kid: string | null = key.kid) =>
  jwt.sign(payload, key.privatePem, { algorithm: "RS256", ...(kid ? { keyid: kid } : {}) })

const b64url = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")

const hmacWithPublicPem = (payload: object, headerAlg: string) => {
  const input = `${b64url({ alg: headerAlg, typ: "JWT", kid: staging.kid })}.${b64url(payload)}`
  const signature = createHmac("sha256", staging.publicPem).update(input).digest("base64url")
  return `${input}.${signature}`
}

const expectRefused = (token: string, message?: RegExp) => {
  expect(() => verifyPortalToken(token, AUDIENCE, keys)).toThrow(PortalTokenError)
  if (message) expect(() => verifyPortalToken(token, AUDIENCE, keys)).toThrow(message)
}

describe("verifyPortalToken", () => {
  it("accepts a token signed by the key its kid names, for that key's issuer", () => {
    expect(verifyPortalToken(sign(claims()), AUDIENCE, keys)).toMatchObject({ uid: 42, iss: staging.iss })
  })

  it("refuses the staging key claiming the production issuer", () => {
    expectRefused(sign(claims({ iss: production.iss })), /issuer invalid/)
  })

  it("refuses the production key under the staging kid", () => {
    expectRefused(sign(claims(), production, staging.kid), /invalid signature/)
  })

  it("refuses an unknown kid rather than falling back to a configured key", () => {
    expectRefused(sign(claims(), staging, "retired-2025"), /unknown or missing kid/)
  })

  it("refuses a token with no kid", () => {
    expectRefused(sign(claims(), staging, null), /unknown or missing kid/)
  })

  it("refuses HS256 signed with the configured public key as the HMAC secret", () => {
    expectRefused(hmacWithPublicPem(claims(), "HS256"), /invalid algorithm/)
  })

  it("refuses an HMAC signature under a header that claims RS256", () => {
    expectRefused(hmacWithPublicPem(claims(), "RS256"), /invalid signature/)
  })

  it("refuses alg none", () => {
    expectRefused(`${b64url({ alg: "none", typ: "JWT", kid: staging.kid })}.${b64url(claims())}.`)
  })

  it("refuses another audience", () => {
    expectRefused(sign(claims({ aud: "report-server" })), /audience invalid/)
  })

  it("refuses a token with no aud", () => {
    const { aud, ...rest } = claims()
    expectRefused(sign(rest))
  })

  it("refuses an aud array even when it contains the expected audience", () => {
    expectRefused(sign(claims({ aud: [AUDIENCE] })), /aud must be a single string/)
  })

  it("refuses an expired token", () => {
    expectRefused(sign(claims({ exp: now() - 1 })), /expired/)
  })

  it("refuses a token with no exp", () => {
    const { exp, ...rest } = claims()
    expectRefused(sign(rest), /exp is required/)
  })

  it("refuses a token with no numeric uid", () => {
    expectRefused(sign(claims({ uid: "42" })), /uid is required/)
  })

  it("refuses garbage", () => {
    expectRefused("not.a.jwt")
    expectRefused("")
    expectRefused(`${b64url({ alg: "RS256", typ: "JWT", kid: staging.kid })}.${Buffer.from("not json").toString("base64url")}.sig`)
  })
})

describe("parsePortalKeys", () => {
  it("reads the value firebase-tools produces from a single-quoted .env line", () => {
    // firebase-tools needs a newer module resolver than this Jest, so its parser runs in node
    const script = `const { envs, errors } = require("firebase-tools/lib/functions/env").parse(process.argv[1]);
      process.stdout.write(JSON.stringify({ value: envs.PORTAL_PUBLIC_KEYS, errors }))`
    const parsed = JSON.parse(execFileSync(process.execPath, ["-e", script, `PORTAL_PUBLIC_KEYS='${keysJson}'\n`]).toString())

    expect(parsed.errors).toEqual([])
    expect(Array.from(parsePortalKeys(parsed.value).keys())).toEqual([staging.kid, production.kid])
  })

  it("treats an empty value as no keys", () => {
    expect(parsePortalKeys("").size).toBe(0)
  })

  it("throws on malformed JSON, a non-array, a missing or empty field, a bad PEM or a repeated kid", () => {
    const entry = { kid: staging.kid, iss: staging.iss, pem: staging.publicPem }
    expect(() => parsePortalKeys("{not json")).toThrow()
    expect(() => parsePortalKeys(JSON.stringify(entry))).toThrow(/JSON array/)
    expect(() => parsePortalKeys(JSON.stringify([{ kid: "k", iss: "i" }]))).toThrow(/kid, iss and pem/)
    expect(() => parsePortalKeys(JSON.stringify([{ ...entry, iss: "" }]))).toThrow(/kid, iss and pem/)
    expect(() => parsePortalKeys(JSON.stringify([{ ...entry, pem: "not a pem" }]))).toThrow()
    expect(() => parsePortalKeys(JSON.stringify([entry, entry]))).toThrow(/more than once/)
  })
})
