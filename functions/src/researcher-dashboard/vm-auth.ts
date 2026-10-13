import express from "express"
import { portalSegment } from "./firestore-paths"
import { Researcher } from "./run-package"
import { PLATFORM_USER_ID } from "./storage-policy"

/** The claims of a verified Firebase ID token that this module reads. */
export interface RunnerClaims {
  uid: string
  platform_id?: unknown
  platform_user_id?: unknown
  user_type?: unknown
  researcher_dashboard_runner?: unknown
  /** When the session signed in, in seconds; refreshing its ID token keeps it. */
  auth_time?: unknown
  /** When the VM first signed in, in seconds, carried into every token /work mints for it. */
  runner_signed_in_at?: unknown
  [claim: string]: unknown
}

/**
 * The researcher a VM's token names, the Firebase uid it signed in as, and when the VM first
 * signed in: a token /work minted says so in runner_signed_in_at, since signing in with it starts
 * a session with a new auth_time.
 */
export interface Runner extends Researcher {
  firebaseUid: string
  signedInAt: number
}

const platformUrl = (value: unknown): URL | null => {
  if (typeof value !== "string") {
    return null
  }
  try {
    const url = new URL(value)
    return url.protocol === "https:" || url.protocol === "http:" ? url : null
  } catch {
    return null
  }
}

/** The runner a token's claims name, or null when they are not a researcher's runner token. */
export function runnerFromClaims(claims: RunnerClaims): Runner | null {
  if (claims.researcher_dashboard_runner !== true || claims.user_type !== "researcher") {
    return null
  }
  const id = claims.platform_user_id
  const platformUserId = typeof id === "number" ? String(id) : id
  if (typeof platformUserId !== "string" || !PLATFORM_USER_ID.test(platformUserId)) {
    return null
  }
  const uid = Number(platformUserId)
  const signedIn = claims.runner_signed_in_at ?? claims.auth_time
  if (!Number.isSafeInteger(uid) || !platformUrl(claims.platform_id) || !Number.isInteger(signedIn)) {
    return null
  }
  const platformId = claims.platform_id as string
  return {
    uid, platformUserId, platformId, portal: portalSegment(platformId), firebaseUid: claims.uid, signedInAt: (signedIn as number) * 1000
  }
}

/**
 * Authenticates the VM by its own Firebase ID token for this project, and requires the runner
 * claim: the browser holds a token for the same researcher in the same project. Sets
 * `res.locals.runner` from the token alone.
 */
export function runnerAuth(verify: () => (idToken: string) => Promise<RunnerClaims>) {
  return async (req: express.Request, res: express.Response, next: express.NextFunction) => {
    const [scheme, token] = (req.headers.authorization ?? "").split(" ")
    if (scheme !== "Bearer" || !token) {
      return res.error(401, "An Authorization: Bearer Firebase ID token is required")
    }

    let claims: RunnerClaims
    try {
      claims = await verify()(token)
    } catch {
      return res.error(401, "Invalid Firebase ID token")
    }
    const runner = runnerFromClaims(claims)
    if (!runner) {
      return res.error(403, "Only a researcher dashboard runner token is accepted")
    }
    res.locals.runner = runner
    next()
    return
  }
}
