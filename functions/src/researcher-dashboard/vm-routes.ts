import express from "express"
import { MAXIMUM_DURATION_SECONDS, UPSTREAM_TIMEOUT_MS, VmDoc, within } from "./ensure-vm"
import { packageKey, vmPath } from "./firestore-paths"
import { MicrovmApi } from "./microvm"
import { heldBy, prune, readQueue, toMillis, withStanding } from "./queue"
import { Db, Refusal, WorkDoc, WorkEntry } from "./run-package"
import type { StorageBroker } from "./storage-broker"
import { REGION } from "./region"
import { BrokerRefusal } from "./storage-policy"
import { Runner, RunnerClaims } from "./vm-auth"

export interface VmRouteDeps {
  db: Db
  verifyIdToken(idToken: string): Promise<RunnerClaims>
  microvms: Pick<MicrovmApi, "suspend">
  broker: StorageBroker
  /** Mints a Firebase custom token for this project. */
  mint(uid: string, claims: Record<string, unknown>): Promise<string>
  /** This function's own Firebase project, the only one it can mint for. */
  ownProject: string
  now(): number
  log: { error(message: string, data: object): void }
  config: { bucket: string; brokerRoleArn: string; audience: string }
}

const reason = (e: unknown) => e instanceof Error ? e.message : String(e)

const microvmIdOf = (body: unknown): string | null => {
  const id = (body as { microvm_id?: unknown } | null)?.microvm_id
  return typeof id === "string" && id !== "" ? id : null
}

/** Refuses (409) any VM but the researcher's recorded one. */
function requireRecorded(vm: VmDoc | undefined, microvmId: string) {
  if (vm?.microvm_id !== microvmId) {
    throw new Refusal(409, `${microvmId} is not this researcher's recorded VM`)
  }
}

// The runner's claims as a verifier sees them; rigse's user_id is replaced by the uid in every
// ID token, so nothing reads it.
const identity = (who: Runner) => ({
  platform_id: who.platformId,
  platform_user_id: who.uid,
  user_type: "researcher",
  researcher_dashboard_runner: true
})

/** POST /work: the queued packages, their scopes, and fresh tokens to run them with. */
export function makeWork(deps: VmRouteDeps) {
  return async (req: express.Request, res: express.Response) => {
    const who = res.locals.runner as Runner
    const microvmId = microvmIdOf(req.body)
    if (!microvmId) {
      return res.error(400, "microvm_id is required")
    }

    let taken: { queued: WorkEntry[]; work: WorkDoc | undefined; vm: VmDoc | undefined }
    try {
      taken = await deps.db.runTransaction(async tx => {
        const recorded = (await tx.get(deps.db.doc(vmPath(who.portal, who.platformUserId)))).data() as VmDoc | undefined
        requireRecorded(recorded, microvmId)
        const q = await readQueue(deps.db, tx, who)
        prune(tx, q)
        return { queued: withStanding(q, "queued"), work: q.work, vm: recorded }
      })
    } catch (e) {
      if (e instanceof Refusal) {
        return res.error(e.status, e.message)
      }
      deps.log.error("work failed", { platformUserId: who.platformUserId, portal: who.portal, error: reason(e) })
      return res.error(500, "work failed")
    }

    const { queued, work, vm } = taken
    const scopes: Record<string, { scope: unknown; class_tokens: Record<string, string> }> = {}
    for (const hash of new Set(queued.map(e => e.class_hash))) {
      const s = work?.scopes?.[hash]
      if (s) {
        scopes[hash] = { scope: s.scope, class_tokens: { ...s.class_tokens } }
      }
    }
    let sessionToken: string | null = work?.session_token ?? null
    const firebaseProject: string | null = work?.firebase_project ?? null

    // Minted only for the recorded VM while it can still exist, so a runner token cannot renew
    // itself past the VM that holds it, and only for the classes being handed out.
    const live = toMillis(vm?.launched_at) > deps.now() - MAXIMUM_DURATION_SECONDS * 1000
    if (live && firebaseProject === deps.ownProject) {
      const hashes = Object.keys(scopes)
      try {
        // Each mint is a signBlob call; together they get one upstream call's time.
        const [session, ...classTokens] = await within(Promise.all([
          deps.mint(who.firebaseUid, identity(who)),
          ...hashes.map(hash => deps.mint(who.firebaseUid, { ...identity(who), class_hash: hash }))
        ]), UPSTREAM_TIMEOUT_MS)
        sessionToken = session
        hashes.forEach((hash, i) => {
          scopes[hash].class_tokens[firebaseProject] = classTokens[i]
        })
      } catch (e) {
        return res.error(502, `the runner's tokens could not be minted: ${reason(e)}`)
      }
    }

    return res.status(200).json({
      success: true,
      packages: queued.map(e => ({
        class_hash: e.class_hash, package_key: packageKey(e.identity), identity: e.identity,
        version: e.version, checksum: e.checksum, catalog_id: e.catalog_id
      })),
      scopes,
      session_token: sessionToken,
      firebase_project: firebaseProject
    })
  }
}

type IdleAnswer = "work_queued" | "run_in_progress" | "suspend"

/** POST /idle: suspends the calling VM unless work was queued meanwhile or it holds a run. */
export function makeIdle(deps: VmRouteDeps) {
  return async (req: express.Request, res: express.Response) => {
    const who = res.locals.runner as Runner
    const microvmId = microvmIdOf(req.body)
    if (!microvmId) {
      return res.error(400, "microvm_id is required")
    }

    let answer: IdleAnswer
    try {
      // Every read before any write: Firestore refuses a read after prune() has written.
      answer = await deps.db.runTransaction(async tx => {
        const recorded = (await tx.get(deps.db.doc(vmPath(who.portal, who.platformUserId)))).data() as VmDoc | undefined
        const q = await readQueue(deps.db, tx, who)
        let next: IdleAnswer = "suspend"
        if (withStanding(q, "queued").length > 0) {
          next = "work_queued"
        } else if (q.entries.some(e => e.standing === "running" && heldBy(e.result?.microvm_id, microvmId))) {
          // The runner never asks mid-run, so suspending would only interrupt a run it lost track of.
          next = "run_in_progress"
        } else {
          requireRecorded(recorded, microvmId)
        }
        prune(tx, q)
        return next
      })
    } catch (e) {
      if (e instanceof Refusal) {
        return res.error(e.status, e.message)
      }
      deps.log.error("idle failed", { platformUserId: who.platformUserId, portal: who.portal, error: reason(e) })
      return res.error(500, "idle failed")
    }
    if (answer === "work_queued") {
      return res.status(200).json({ success: true, suspended: false, work_queued: true })
    }
    if (answer === "run_in_progress") {
      return res.status(200).json({ success: true, suspended: false, run_in_progress: true })
    }

    // Work queued from here on lands on a SUSPENDING VM, which the watchdog resumes.
    try {
      await deps.microvms.suspend(microvmId)
    } catch (e) {
      return res.error(502, `SuspendMicrovm failed: ${reason(e)}`)
    }
    return res.status(200).json({ success: true, suspended: true })
  }
}

/** POST /storage-credentials: the storage broker. */
export function makeStorageCredentials(deps: VmRouteDeps) {
  return async (req: express.Request, res: express.Response) => {
    const who = res.locals.runner as Runner
    const { bucket, brokerRoleArn, audience } = deps.config
    const unset = [!brokerRoleArn && "RD_BROKER_ROLE_ARN", !bucket && "RD_DATA_BUCKET", !audience && "RD_AWS_AUDIENCE"].filter(Boolean)
    if (unset.length > 0) {
      return res.error(503, `researcherDashboard is not configured: ${unset.join(", ")} unset`)
    }

    try {
      const c = await deps.broker.assume({ roleArn: brokerRoleArn, audience, bucket, platformUserId: who.platformUserId })
      return res.status(200).json({
        success: true,
        access_key_id: c.accessKeyId,
        secret_access_key: c.secretAccessKey,
        session_token: c.sessionToken,
        expiration: c.expiration.toISOString(),
        bucket,
        prefix: `researchers/${who.platformUserId}/`,
        region: REGION
      })
    } catch (e) {
      if (e instanceof BrokerRefusal) {
        return res.error(503, `the storage broker is misconfigured: ${e.message}`)
      }
      return res.error(502, `the storage broker failed: ${reason(e)}`)
    }
  }
}
