import express from "express"
import responseMethods from "../middleware/response-methods"
import requireHeaderBearer from "../middleware/require-header-bearer"
import { PortalKeys, verifyPortalToken } from "./portal-token"
import { portalSegment } from "./firestore-paths"
import { makeRunPackage, Researcher, RunPackageDeps } from "./run-package"
import { DeriveProfileRouteDeps, makeDeriveProfile } from "./derive-profile-route"
import { runnerAuth } from "./vm-auth"
import { makeIdle, makeStorageCredentials, makeWork, VmRouteDeps } from "./vm-routes"

const FUNCTIONS_AUDIENCE = "report-service-functions"

/**
 * Authenticates by an `aud: report-service-functions` assertion rigse signed, and sets
 * `res.locals.researcher` from its claims. The function app's shared bearer is not accepted.
 */
export function portalAssertionAuth(keys: () => PortalKeys) {
  return (req: express.Request, res: express.Response, next: express.NextFunction) => {
    const [scheme, token] = (req.headers.authorization ?? "").split(" ")
    if (scheme !== "Bearer" || !token) return res.error(401, "An Authorization: Bearer assertion is required")

    let trusted: PortalKeys
    try {
      trusted = keys()
    } catch (e) {
      return res.error(500, `PORTAL_PUBLIC_KEYS is misconfigured: ${e instanceof Error ? e.message : String(e)}`)
    }

    try {
      const claims = verifyPortalToken(token, FUNCTIONS_AUDIENCE, trusted)
      const researcher: Researcher = {
        uid: claims.uid,
        platformUserId: String(claims.uid),
        platformId: claims.iss,
        portal: portalSegment(claims.iss)
      }
      res.locals.researcher = researcher
    } catch {
      return res.error(401, "Invalid assertion")
    }
    next()
    return
  }
}

/**
 * The researcherDashboard function's app. It has no shared-bearer middleware. rigse's routes take
 * its signed assertion; the VM's take the VM's own Firebase ID token with the runner claim, and
 * neither accepts the other's credential.
 */
export function researcherDashboardApp(
  deps: () => RunPackageDeps, deriveDeps: () => DeriveProfileRouteDeps, vmDeps: () => VmRouteDeps
) {
  const app = express()
  app.use(responseMethods)
  app.use(requireHeaderBearer)
  const fromRigse = portalAssertionAuth(() => deps().keys())
  const fromVm = runnerAuth(() => vmDeps().verifyIdToken)
  app.post("/run-package", fromRigse, (req, res) => makeRunPackage(deps())(req, res))
  app.post("/derive-profile", fromRigse, (req, res) => makeDeriveProfile(deriveDeps())(req, res))
  app.post("/work", fromVm, (req, res) => makeWork(vmDeps())(req, res))
  app.post("/idle", fromVm, (req, res) => makeIdle(vmDeps())(req, res))
  app.post("/storage-credentials", fromVm, (req, res) => makeStorageCredentials(vmDeps())(req, res))
  return app
}
