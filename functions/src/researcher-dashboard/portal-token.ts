import jwt from "jsonwebtoken"
import { createPublicKey, KeyObject } from "crypto"

export interface PortalKeyConfig { kid: string; iss: string; pem: string }
export interface PortalKey { iss: string; key: KeyObject }
export type PortalKeys = Map<string, PortalKey>

export interface PortalClaims {
  iss: string
  uid: number
  aud: string
  exp: number
  [claim: string]: unknown
}

export class PortalTokenError extends Error {}

const isNonEmptyString = (value: unknown): value is string => typeof value === "string" && value !== ""

/**
 * Parses `PORTAL_PUBLIC_KEYS`, a JSON array of `{kid, iss, pem}`, one entry per rigse key. Each
 * key is trusted only for its own issuer (portal site URL). Throws on malformed JSON, an entry
 * missing a field, an unreadable PEM or a kid listed twice, since any of them would make which
 * key a token is checked against a guess.
 */
export function parsePortalKeys(json: string): PortalKeys {
  const entries: unknown = JSON.parse(json || "[]")
  if (!Array.isArray(entries)) throw new PortalTokenError("PORTAL_PUBLIC_KEYS must be a JSON array")

  const keys: PortalKeys = new Map()
  for (const entry of entries as Partial<PortalKeyConfig>[]) {
    const { kid, iss, pem } = entry ?? {}
    if (!isNonEmptyString(kid) || !isNonEmptyString(iss) || !isNonEmptyString(pem)) {
      throw new PortalTokenError("each PORTAL_PUBLIC_KEYS entry needs a non-empty kid, iss and pem")
    }
    if (keys.has(kid)) throw new PortalTokenError(`PORTAL_PUBLIC_KEYS lists kid ${kid} more than once`)
    // A KeyObject, not the PEM string, so the public key can never become an HMAC secret.
    keys.set(kid, { iss, key: createPublicKey(pem) })
  }
  return keys
}

/**
 * Verifies an RS256 token rigse signed for `audience`: the key comes from the token's kid, the
 * issuer must be that key's, and the algorithm is pinned. Returns the claims or throws
 * PortalTokenError.
 */
export function verifyPortalToken(token: string, audience: string, keys: PortalKeys): PortalClaims {
  let entry: PortalKey | undefined
  let claims: PortalClaims
  try {
    const kid = jwt.decode(token, { complete: true })?.header?.kid
    entry = kid ? keys.get(kid) : undefined
    if (!entry) throw new PortalTokenError("unknown or missing kid")
    claims = jwt.verify(token, entry.key, { algorithms: ["RS256"], issuer: entry.iss, audience }) as PortalClaims
  } catch (e) {
    if (e instanceof PortalTokenError) throw e
    throw new PortalTokenError(e instanceof Error ? e.message : String(e))
  }
  // Checked here as well, since jsonwebtoken skips the issuer check for a falsy issuer and
  // accepts a token with no exp or with an aud array containing the expected value.
  if (claims.iss !== entry.iss) throw new PortalTokenError("wrong issuer")
  if (typeof claims.aud !== "string") throw new PortalTokenError("aud must be a single string")
  if (typeof claims.exp !== "number") throw new PortalTokenError("exp is required")
  if (typeof claims.uid !== "number") throw new PortalTokenError("uid is required")
  return claims
}
