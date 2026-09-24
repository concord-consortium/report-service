import express from "express"
import cors from "cors"
import admin from "firebase-admin"
import * as functions from "firebase-functions"

import bearerTokenAuth, { bearerToken } from "./middleware/bearer-token-auth"
import responseMethods from "./middleware/response-methods"

import importRun from "./api/import-run"
import importStructure from "./api/import-structure"
import moveStudentWork from "./api/move-student-work"
import getResource from "./api/get-resource"
import getAnswer from "./api/get-answer"
import getPluginStates from "./api/get-plugin-states"
import getStudentFeedbackMetadata from "./api/get-student-feedback-metadata"
import bulkRead from "./api/bulk-read"
import fetchAttachmentMeta from "./api/attachment-meta"
import requireHeaderBearer from "./middleware/require-header-bearer"

import {
  createSyncDocAfterAnswerWritten,
  monitorSyncDocCount,
  syncToS3AfterSyncDocWritten
} from "./auto-importer";

import { submitTask } from "./tasks/submit-task";
import { taskWorker } from "./tasks/task-worker";

import { chatTutorOnWrite } from "./chat-tutor"; // per-page AI chat tutor trigger

import { researcherDashboardApp } from "./researcher-dashboard/app"
import { RunPackageDeps, Db } from "./researcher-dashboard/run-package"
import { parsePortalKeys, PortalKeys } from "./researcher-dashboard/portal-token"
import {
  functionUrl, portalPublicKeys, rdAwsKey, rdAwsSecretKey, rdDataBucket, rdExecutionRoleArn, rdMicrovmImageArn,
  rdQueueCap, rdReportServerUrl, unsetLaunchSettings
} from "./researcher-dashboard/config"
import { ensureVm, EnsureVmDeps } from "./researcher-dashboard/ensure-vm"
import { makeMicrovmApi, MicrovmApi } from "./researcher-dashboard/microvm"

const packageJSON = require("../package.json")
const buildInfo = require("../build-info.json")

admin.initializeApp();

const api = express()
api.use(cors({ origin: true }))
api.use(responseMethods)
api.use(bearerTokenAuth)
api.get("/", (req, res) => {
  res.success({
    description: "Report service API",
    version: packageJSON.version,
    buildInfo,
    methods: {
      "POST import_run": "Imports a run, requires a bearer token!!",
      "POST import_structure": "Imports the structure, requires a bearer token",
      "POST move_student_work": "Moves a students work from one class to another, requires a bearer token.",
      "GET resource?source=<SOURCE>&url=<URL>": "Returns a resource under source with given url",
      "GET answer?source=<SOURCE>&remote_endpoint=<REMOTE_ENDPOINT>&question_id=<QUESTION_ID>": "Returns the full answer document for a question by a learner",
      "GET plugin_states?source=<SOURCE>&remote_endpoint=<REMOTE_ENDPOINT>": "Returns all the plugin states for a learner's resource",
      "GET student_feedback_metadata?source=<SOURCE>&platform_id=<PLATFORM_ID>&platform_student_id=<PLATFORM_STUDENT_ID>": "Returns a map, keyed by offering id, of the student's activity and question feedback metadata",
      "POST bulk_read": "STORY 3: bulk answers/history read for a report run's authorized endpoints (Elixir-only, header bearer required)",
      "POST fetch_attachment_meta": "STORY 3: authoritative attachment metadata (publicPath/owner/contentType) for a batch of docs (Elixir-only, header bearer required)",
    }
  })
})
api.post("/import_run", importRun)
api.post("/import_structure", importStructure)
api.post("/move_student_work", moveStudentWork)
api.get("/resource", getResource)
api.get("/answer", getAnswer)
api.get("/plugin_states", getPluginStates)
api.get("/student_feedback_metadata", getStudentFeedbackMetadata)
api.post("/bulk_read", requireHeaderBearer, bulkRead)
api.post("/fetch_attachment_meta", requireHeaderBearer, fetchAttachmentMeta)

// Takes a standard express app and transforms it into a firebase function
// handler that behaves 'correctly' with respect to trailing slashes.
const wrappedApi = functions
  .runWith({ secrets: [bearerToken], timeoutSeconds: 300 })   // STORY 3: headroom for a slow bulk page; ceiling, not a cost floor
  .https.onRequest( (req: express.Request, res: express.Response) =>  {
    if (!req.path) {
      req.url = `/${req.url}` // prepend '/' to keep query params if any
    }
    api(req, res)
  })

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
const researcherDashboard = functions
  .runWith({ secrets: [rdAwsKey, rdAwsSecretKey], timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp(researcherDashboardDeps))

module.exports = {
  api: wrappedApi,
  createSyncDocAfterAnswerWritten,
  monitorSyncDocCount,
  syncToS3AfterSyncDocWritten,
  submitTask,
  taskWorker,
  chatTutorOnWrite, // per-page AI chat tutor trigger
  researcherDashboard,
}
