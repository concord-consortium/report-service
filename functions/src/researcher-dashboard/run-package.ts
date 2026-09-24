import express from "express"
import { PortalKeys, verifyPortalToken } from "./portal-token"
import { packageKey, resultPath, runnerPath, workPath } from "./firestore-paths"
import { VmOutcome, VmStepError } from "./ensure-vm"

export interface Researcher {
  uid: number
  platformUserId: string
  platformId: string
  portal: string
}

export interface PackageRef { identity: string; version: string; checksum: string; catalog_id: number }
export interface Assignment { offering_id: number; runnable_id: number; name: string | null; url: string }
export interface ScopeBlock {
  kind: "class"
  collection: "classes"
  id: string
  classes: { class_hash: string; class_id: number }[]
  assignments: Assignment[]
}
export interface RunPackageBody {
  packages: PackageRef[]
  scope: ScopeBlock
  class_tokens: Record<string, string>
  session_token: string
  firebase_project: string
  report_server_assertion: string
}

export interface WorkEntry extends PackageRef { class_hash: string }
export interface WorkDoc {
  packages?: WorkEntry[]
  scopes?: Record<string, { scope: ScopeBlock; class_tokens: Record<string, string> }>
}
export interface QueueEntry { class_hash: string; package_key: string }

// The slice of the Admin SDK's Firestore this module uses, so tests can hand it a fake.
export interface Snapshot { data(): unknown }
export interface DocRef { path: string; get(): Promise<Snapshot> }
export interface Transaction {
  get(ref: DocRef): Promise<Snapshot>
  set(ref: DocRef, data: object, options?: { merge?: boolean; mergeFields?: string[] }): unknown
}
export interface Db {
  doc(path: string): DocRef
  runTransaction<T>(fn: (tx: Transaction) => Promise<T>): Promise<T>
}

export interface RunPackageDeps {
  db: Db
  keys(): PortalKeys
  // admin.firestore.FieldValue.serverTimestamp() in production, so the watchdog can range-query it
  timestamp(): unknown
  ensureVm(who: Researcher, body: RunPackageBody): Promise<VmOutcome>
  log: { error(message: string, data: object): void }
  config: { queueCap: number }
}

export class Refusal extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

const IDENTITY = /^(users|projects)\/[0-9]+\/[a-z0-9][a-z0-9-]{0,62}$/
const CHECKSUM = /^sha256:[0-9a-f]{64}$/
// rigse's SecureRandom.hex(24); it becomes a Firestore path segment
const CLASS_HASH = /^[0-9a-f]{48}$/

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const isNonEmptyString = (v: unknown): v is string => typeof v === "string" && v !== ""
const isPositiveInteger = (v: unknown): v is number => Number.isInteger(v) && (v as number) > 0

function packagesProblem(packages: unknown): string | null {
  if (!Array.isArray(packages) || packages.length === 0) return "packages must be a non-empty array"
  const seen = new Set<string>()
  for (const [i, p] of packages.entries()) {
    const at = `packages[${i}]`
    if (!isObject(p)) return `${at} must be an object`
    if (typeof p.identity !== "string" || !IDENTITY.test(p.identity)) return `${at}.identity must be <users|projects>/<id>/<name>`
    if (!isNonEmptyString(p.version)) return `${at}.version is required`
    if (typeof p.checksum !== "string" || !CHECKSUM.test(p.checksum)) return `${at}.checksum must be sha256:<64 lowercase hex>`
    if (!isPositiveInteger(p.catalog_id)) return `${at}.catalog_id must be a positive integer`
    if (seen.has(p.identity)) return `${at}.identity is listed twice`
    seen.add(p.identity)
  }
  return null
}

function scopeProblem(scope: unknown): string | null {
  if (!isObject(scope)) return "scope is required"
  if (scope.kind !== "class" || scope.collection !== "classes") return "scope must be {kind: \"class\", collection: \"classes\"}"
  const classes = scope.classes
  if (!Array.isArray(classes) || classes.length !== 1) return "scope.classes must hold exactly one class"
  const [clazz] = classes
  if (!isObject(clazz) || typeof clazz.class_hash !== "string" || !CLASS_HASH.test(clazz.class_hash)) {
    return "scope.classes[0].class_hash must be 48 lowercase hex characters"
  }
  if (!isPositiveInteger(clazz.class_id)) return "scope.classes[0].class_id must be a positive integer"
  if (scope.id !== clazz.class_hash) return "scope.id must be the class's class_hash"
  if (!Array.isArray(scope.assignments)) return "scope.assignments must be an array"
  for (const [i, a] of scope.assignments.entries()) {
    const at = `scope.assignments[${i}]`
    if (!isObject(a)) return `${at} must be an object`
    if (!isPositiveInteger(a.offering_id) || !isPositiveInteger(a.runnable_id)) return `${at} needs positive integer offering_id and runnable_id`
    if (a.name !== null && typeof a.name !== "string") return `${at}.name must be a string or null`
    if (typeof a.url !== "string") return `${at}.url must be a string`
  }
  return null
}

function bodyProblem(body: Record<string, unknown>): string | null {
  const problem = packagesProblem(body.packages) ?? scopeProblem(body.scope)
  if (problem) return problem
  const tokens = body.class_tokens
  if (!isObject(tokens) || Object.keys(tokens).length === 0 || !Object.values(tokens).every(isNonEmptyString)) {
    return "class_tokens must map a FirebaseApp name to a token"
  }
  for (const field of ["session_token", "firebase_project", "report_server_assertion"]) {
    if (!isNonEmptyString(body[field])) return `${field} is required`
  }
  return null
}

// The relayed assertion must name the researcher this request is for, or one researcher's VM
// could be launched holding another's report-server token.
function assertionProblem(assertion: string, who: Researcher, keys: PortalKeys): string | null {
  try {
    const claims = verifyPortalToken(assertion, "report-server", keys)
    if (claims.uid !== who.uid || claims.iss !== who.platformId) return "report_server_assertion names another researcher"
    return null
  } catch (e) {
    return `report_server_assertion is invalid: ${e instanceof Error ? e.message : String(e)}`
  }
}

const entryKey = (e: { class_hash: string; identity: string }) => `${e.class_hash}/${packageKey(e.identity)}`

/**
 * Appends the batch to the researcher's queue, keyed by class and package, and writes a
 * `queued` result for each package appended, in one transaction: a refusal writes nothing.
 * Returns the whole queue and the keys appended.
 */
export async function queuePackages(deps: RunPackageDeps, who: Researcher, body: RunPackageBody) {
  const { portal, platformUserId, platformId } = who
  const classHash = body.scope.classes[0].class_hash
  const now = deps.timestamp()

  return deps.db.runTransaction(async tx => {
    const workRef = deps.db.doc(workPath(portal, platformUserId))
    const work = (await tx.get(workRef)).data() as WorkDoc | undefined
    const existing = work?.packages ?? []
    const queued = new Set(existing.map(entryKey))
    const appended: WorkEntry[] = body.packages
      .map(({ identity, version, checksum, catalog_id }) => ({ identity, version, checksum, catalog_id, class_hash: classHash }))
      .filter(p => !queued.has(entryKey(p)))
    const packages = [...existing, ...appended]
    if (packages.length > deps.config.queueCap) {
      throw new Refusal(409, `queue at its cap (${deps.config.queueCap} outstanding)`)
    }

    // replaces this class's scope and tokens whole, keeping other classes'
    tx.set(workRef, {
      packages,
      scopes: { [classHash]: { scope: body.scope, class_tokens: body.class_tokens } },
      session_token: body.session_token,
      firebase_project: body.firebase_project,
      updated_at: now
    }, { mergeFields: ["packages", `scopes.${classHash}`, "session_token", "firebase_project", "updated_at"] })

    for (const p of appended) {
      tx.set(deps.db.doc(resultPath(portal, classHash, platformUserId, packageKey(p.identity))), {
        status: "queued",
        queued_at: now,
        updated_at: now,
        platform_id: platformId,
        package: { identity: p.identity, version: p.version, checksum: p.checksum }
      })
    }

    const queue: QueueEntry[] = packages.map(e => ({ class_hash: e.class_hash, package_key: packageKey(e.identity) }))
    tx.set(deps.db.doc(runnerPath(portal, platformUserId)), { queue, platform_id: platformId, updated_at: now }, { merge: true })

    return { queue, appended: appended.map(p => packageKey(p.identity)) }
  })
}

/** POST /run-package. Expects `res.locals.researcher` from the portal-assertion middleware. */
export function makeRunPackage(deps: RunPackageDeps) {
  return async function runPackage(req: express.Request, res: express.Response) {
    const who = res.locals.researcher as Researcher
    const body: Record<string, unknown> = isObject(req.body) ? req.body : {}

    const problem = bodyProblem(body) ?? assertionProblem(body.report_server_assertion as string, who, deps.keys())
    if (problem) return res.error(400, problem)
    const valid = body as unknown as RunPackageBody

    try {
      const queued = await queuePackages(deps, who, valid)
      const vm = await deps.ensureVm(who, valid)
      return res.status(202).json({ success: true, ...queued, vm })
    } catch (e) {
      if (e instanceof Refusal) return res.error(e.status, e.message)
      // the work is already queued, and the next request or the VM itself will take it
      if (e instanceof VmStepError) {
        deps.log.error("run-package VM step failed", { platformUserId: who.platformUserId, portal: who.portal, error: e.message })
        return res.error(e.status, e.message)
      }
      deps.log.error("run-package failed", { platformUserId: who.platformUserId, portal: who.portal, error: String(e) })
      return res.error(500, "run-package failed")
    }
  }
}
