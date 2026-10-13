import admin from "firebase-admin"
import * as functions from "firebase-functions"

import { researcherDashboardApp } from "./app"
import { brokerIdToken, functionCredentials } from "./aws-credentials"
import {
  functionUrl, portalPublicKeys, rdAuthoringHosts, rdAwsAudience, rdBrokerRoleArn, rdDataBucket, rdExecutionRoleArn,
  rdLauncherRoleArn, rdMicrovmImageArn, rdQueueCap, rdReportServerUrl, SERVICE_ACCOUNT_ID, unsetLaunchSettings
} from "./config"
import { DeriveProfileRouteDeps, parseAllowedHosts } from "./derive-profile-route"
import { defaultDerivationDeps, enqueueDerivation } from "./derive-profile-worker"
import { ensureVm, EnsureVmDeps } from "./ensure-vm"
import { makeMicrovmApi, MicrovmApi } from "./microvm"
import { parsePortalKeys, PortalKeys } from "./portal-token"
import { RunPackageDeps, Db } from "./run-package"
import { makeStorageBroker } from "./storage-broker"
import { RunnerClaims } from "./vm-auth"
import { VmRouteDeps } from "./vm-routes"

// Parsed once per configured value rather than per request.
let parsedKeys: { json: string; keys: PortalKeys } | null = null
function trustedPortalKeys(): PortalKeys {
  const json = portalPublicKeys.value()
  if (parsedKeys?.json !== json) {
    parsedKeys = { json, keys: parsePortalKeys(json) }
  }
  return parsedKeys.keys
}

// Built on first use and kept for the instance's life; its credentials refresh themselves.
let microvms: MicrovmApi | null = null
function microvmApi(): MicrovmApi {
  const launcher = () => ({ roleArn: rdLauncherRoleArn.value(), audience: rdAwsAudience.value() })
  microvms ??= makeMicrovmApi(functionCredentials(launcher, "researcher-dashboard-launcher"))
  return microvms
}

// Holds no credentials: each session is assumed with a token minted for it.
const storageBroker = makeStorageBroker(brokerIdToken())

function vmRouteDeps(): VmRouteDeps {
  return {
    db: admin.firestore() as unknown as Db,
    verifyIdToken: t => admin.auth().verifyIdToken(t) as Promise<RunnerClaims>,
    microvms: microvmApi(),
    broker: storageBroker,
    // Signs as the function's own account through the IAM Service Account Credentials API, which
    // needs Token Creator on itself (scripts/setup-researcher-dashboard-iam.sh).
    mint: (uid, claims) => admin.auth().createCustomToken(uid, claims),
    ownProject: process.env.GCLOUD_PROJECT ?? "",
    now: Date.now,
    log: functions.logger,
    config: { bucket: rdDataBucket.value(), brokerRoleArn: rdBrokerRoleArn.value(), audience: rdAwsAudience.value() }
  }
}

function researcherDashboardDeps(): RunPackageDeps {
  const db = admin.firestore() as unknown as Db
  const timestamp = () => admin.firestore.FieldValue.serverTimestamp()
  const vmDeps: EnsureVmDeps = {
    db,
    microvms: microvmApi(),
    fetchImpl: fetch,
    now: Date.now,
    timestamp,
    config: {
      imageIdentifier: rdMicrovmImageArn.value(),
      executionRoleArn: rdExecutionRoleArn.value(),
      bucket: rdDataBucket.value(),
      reportServerUrl: rdReportServerUrl.value(),
      functionUrl: functionUrl()
    }
  }
  return {
    db,
    keys: trustedPortalKeys,
    timestamp,
    ensureVm: (who, body) => ensureVm(vmDeps, who, body),
    log: functions.logger,
    config: { queueCap: rdQueueCap.value() },
    unconfigured: unsetLaunchSettings()
  }
}

function deriveProfileDeps(): DeriveProfileRouteDeps {
  const allowedHosts = () => parseAllowedHosts(rdAuthoringHosts.value())
  return {
    enqueue: task => enqueueDerivation(task, () => defaultDerivationDeps(allowedHosts()), functions.logger),
    allowedHosts,
    now: Date.now
  }
}

// The Researcher Dashboard's function surface, authenticated by rigse's signed assertions and the
// VM's own Firebase ID token rather than the shared bearer. It runs as its own service account, so
// the runner stack's roles, which trust only that account, cannot be assumed from any other function
// in the project.
export const researcherDashboard = functions
  .runWith({ serviceAccount: `${SERVICE_ACCOUNT_ID}@`, timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp(researcherDashboardDeps, deriveProfileDeps, vmRouteDeps))

export { deriveProfileWorker } from "./derive-profile-task"
