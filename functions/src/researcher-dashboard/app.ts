import express from "express"
import responseMethods from "../middleware/response-methods"
import requireHeaderBearer from "../middleware/require-header-bearer"
import { PortalKeys, verifyPortalToken } from "./portal-token"
import { portalSegment } from "./firestore-paths"
import { makeRunPackage, Researcher, RunPackageDeps } from "./run-package"

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

/** The researcherDashboard function's app. It has no shared-bearer middleware. */
export function researcherDashboardApp(deps: () => RunPackageDeps) {
  const app = express()
  app.use(responseMethods)
  app.use(requireHeaderBearer)
  app.use(portalAssertionAuth(() => deps().keys()))
  app.post("/run-package", (req, res) => makeRunPackage(deps())(req, res))
  return app
}
