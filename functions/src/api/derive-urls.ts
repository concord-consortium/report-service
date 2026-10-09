import express from "express"
import { deriveProfile, ProfileDeps } from "../researcher-dashboard/derive-profile"
import { assignmentUrlsProblem, MAX_BODY_BYTES } from "../researcher-dashboard/derive-profile-route"

export type DeriveUrlsDeps = Pick<ProfileDeps, "fetchImpl" | "allowedHosts" | "budgetMs" | "now">

/**
 * report-server's applies route: the interactive URLs inside assignment URLs, from the same
 * deriver /derive-profile uses. It writes nothing and takes no class, so the classes/{class_hash}
 * profile stays the rigse and app path's. The URLs come from a researcher, so the host allowlist
 * is the only defense on what it fetches.
 */
export function makeDeriveUrls(deps: () => DeriveUrlsDeps) {
  return async (req: express.Request, res: express.Response) => {
    const d = deps()
    if (d.allowedHosts.size === 0) {
      return res.error(503, "derive_urls is not configured: RD_AUTHORING_HOSTS unset")
    }
    const body = req.body
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return res.error(400, "the body must be a JSON object")
    }
    if (Buffer.byteLength(JSON.stringify(body)) > MAX_BODY_BYTES) {
      return res.error(400, "the body exceeds 256 KiB")
    }
    const problem = assignmentUrlsProblem(body.assignment_urls)
    if (problem) {
      return res.error(400, problem)
    }

    try {
      const { interactive_urls, unread, truncated } = await deriveProfile(d, body.assignment_urls)
      return res.success({ interactive_urls, unread, truncated })
    } catch (e) {
      return res.error(502, `the derivation failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }
}
