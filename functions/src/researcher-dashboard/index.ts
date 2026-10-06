import admin from "firebase-admin"
import * as functions from "firebase-functions"

import { researcherDashboardApp } from "./app"
import { functionCredentials } from "./aws-credentials"
import {
  functionUrl, portalPublicKeys, rdAwsAudience, rdDataBucket, rdExecutionRoleArn, rdLauncherRoleArn,
  rdMicrovmImageArn, rdQueueCap, rdReportServerUrl, SERVICE_ACCOUNT_ID, unsetLaunchSettings
} from "./config"
import { ensureVm, EnsureVmDeps } from "./ensure-vm"
import { makeMicrovmApi, MicrovmApi } from "./microvm"
import { parsePortalKeys, PortalKeys } from "./portal-token"
import { RunPackageDeps, Db } from "./run-package"

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

// The Researcher Dashboard's function surface, authenticated by rigse's signed assertions rather
// than the shared bearer. It runs as its own service account, so the runner stack's roles, which
// trust only that account, cannot be assumed from any other function in the project.
export const researcherDashboard = functions
  .runWith({ serviceAccount: `${SERVICE_ACCOUNT_ID}@`, timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp(researcherDashboardDeps))
