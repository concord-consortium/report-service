import admin from "firebase-admin"
import * as functions from "firebase-functions"

import { researcherDashboardApp } from "./app"
import {
  functionUrl, portalPublicKeys, rdAwsKey, rdAwsSecretKey, rdDataBucket, rdExecutionRoleArn, rdMicrovmImageArn,
  rdQueueCap, rdReportServerUrl, unsetLaunchSettings
} from "./config"
import { ensureVm, EnsureVmDeps } from "./ensure-vm"
import { makeMicrovmApi, MicrovmApi } from "./microvm"
import { parsePortalKeys, PortalKeys } from "./portal-token"
import { RunPackageDeps, Db } from "./run-package"

// Parsed once per configured value rather than per request.
let parsedKeys: { json: string; keys: PortalKeys } | null = null
function trustedPortalKeys(): PortalKeys {
  const json = portalPublicKeys.value()
  if (parsedKeys?.json !== json) parsedKeys = { json, keys: parsePortalKeys(json) }
  return parsedKeys.keys
}

// Built on first use, once the secrets are readable, and kept for the instance's life.
let microvms: MicrovmApi | null = null
function microvmApi(): MicrovmApi {
  microvms ??= makeMicrovmApi({ accessKeyId: rdAwsKey.value(), secretAccessKey: rdAwsSecretKey.value() })
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

// The Researcher Dashboard's function surface, authenticated by rigse's signed assertions
// rather than the shared bearer, and the only function holding the MicroVM launcher's keys.
export const researcherDashboard = functions
  .runWith({ secrets: [rdAwsKey, rdAwsSecretKey], timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp(researcherDashboardDeps))
