import express from "express"
import { Researcher } from "./run-package"

export const MAX_BODY_BYTES = 256 * 1024
const MAX_ASSIGNMENT_URLS = 500
const MAX_URL_LENGTH = 2048
const MAX_FINGERPRINT_LENGTH = 256
// rigse's SecureRandom.hex(24); it becomes a Firestore path segment
const CLASS_HASH = /^[0-9a-f]{48}$/

/** A derivation, as queued: everything the worker needs, with the portal from the assertion. */
export interface DeriveTask {
  portal: string
  platform_id: string
  class_hash: string
  assignment_fingerprint: string
  assignment_urls: string[]
  requested_at: number
}

export interface DeriveProfileRouteDeps {
  enqueue(task: DeriveTask): Promise<void>
  /** The parsed authoring host allowlist; while it is empty, nothing is queued. */
  allowedHosts(): Set<string>
  now(): number
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)

/** The first problem with a /derive-profile body, or null. */
export function deriveBodyProblem(body: unknown): string | null {
  if (!isObject(body)) return "the body must be a JSON object"
  if (Buffer.byteLength(JSON.stringify(body)) > MAX_BODY_BYTES) return "the body exceeds 256 KiB"
  const { class_hash, assignment_fingerprint, assignment_urls } = body
  if (typeof class_hash !== "string" || !CLASS_HASH.test(class_hash)) return "class_hash must be 48 lowercase hex characters"
  if (typeof assignment_fingerprint !== "string" || !assignment_fingerprint || assignment_fingerprint.length > MAX_FINGERPRINT_LENGTH) {
    return `assignment_fingerprint must be a non-empty string of at most ${MAX_FINGERPRINT_LENGTH} characters`
  }
  if (!Array.isArray(assignment_urls) || assignment_urls.length > MAX_ASSIGNMENT_URLS) {
    return `assignment_urls must be an array of at most ${MAX_ASSIGNMENT_URLS} strings`
  }
  if (!assignment_urls.every(u => typeof u === "string" && u.length <= MAX_URL_LENGTH)) {
    return `each assignment URL must be a string of at most ${MAX_URL_LENGTH} characters`
  }
  return null
}

/** The comma-separated RD_AUTHORING_HOSTS value as a set of lowercase hostnames. */
export const parseAllowedHosts = (value: string) =>
  new Set(value.split(",").map(h => h.trim().toLowerCase()).filter(h => h))

export function makeDeriveProfile(deps: DeriveProfileRouteDeps) {
  return async (req: express.Request, res: express.Response) => {
    if (deps.allowedHosts().size === 0) {
      return res.error(503, "researcherDashboard is not configured: RD_AUTHORING_HOSTS unset")
    }
    const problem = deriveBodyProblem(req.body)
    if (problem) return res.error(400, problem)

    const who: Researcher = res.locals.researcher
    const task: DeriveTask = {
      portal: who.portal,
      platform_id: who.platformId,
      class_hash: req.body.class_hash,
      assignment_fingerprint: req.body.assignment_fingerprint,
      assignment_urls: req.body.assignment_urls,
      requested_at: deps.now()
    }
    try {
      await deps.enqueue(task)
    } catch (e) {
      return res.error(502, `the derivation could not be queued: ${e instanceof Error ? e.message : String(e)}`)
    }
    return res.status(202).json({ success: true, queued: true })
  }
}
