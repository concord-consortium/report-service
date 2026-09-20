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

import { defineSecret, defineString } from "firebase-functions/params"
import { makeRunPackage, RunPackageDeps, VmRecord } from "./researcher-dashboard/run-package"
import { makeMicrovmApi } from "./researcher-dashboard/microvm"

import {
  createSyncDocAfterAnswerWritten,
  monitorSyncDocCount,
  syncToS3AfterSyncDocWritten
} from "./auto-importer";

import { submitTask } from "./tasks/submit-task";
import { taskWorker } from "./tasks/task-worker";

import { chatTutorOnWrite } from "./chat-tutor"; // per-page AI chat tutor trigger

// The researcher dashboard's launch surface. Its own AWS identity, not the one
// auto-importer writes answers to S3 with: this key belongs to the
// researcher-dashboard-runner stack's launcher user and grants only lambda-microvms
// calls and PassRole on the runner's execution role. The ARNs and bucket below are that
// stack's outputs and are not secret.
const awsKey = defineSecret("RD_AWS_KEY")
const awsSecretKey = defineSecret("RD_AWS_SECRET_KEY")
const rdImageArn = defineString("RD_MICROVM_IMAGE_ARN")
const rdExecutionRoleArn = defineString("RD_EXECUTION_ROLE_ARN")
const rdBucket = defineString("RD_DATA_BUCKET")
const rdReportServerUrl = defineString("RD_REPORT_SERVER_URL")

// Built on first use, not at module load: a params value cannot be read until the
// function is running.
let runPackageDeps: RunPackageDeps | null = null
function researcherDashboardDeps(): RunPackageDeps {
  if (runPackageDeps) return runPackageDeps
  const vmDoc = (portal: string, platformUserId: string) =>
    admin.firestore().doc(`researcher_dashboard/${portal}/vms/${platformUserId}`)
  runPackageDeps = {
    microvms: makeMicrovmApi({ accessKeyId: awsKey.value(), secretAccessKey: awsSecretKey.value() }),
    loadVm: async (portal, platformUserId) => {
      const snapshot = await vmDoc(portal, platformUserId).get()
      return snapshot.exists ? (snapshot.data() as VmRecord) : null
    },
    saveVm: async (portal, platformUserId, record) => {
      await vmDoc(portal, platformUserId).set(record)
    },
    fetchImpl: fetch,
    now: () => Date.now(),
    sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
    log: functions.logger,
    config: {
      imageIdentifier: rdImageArn.value(),
      executionRoleArn: rdExecutionRoleArn.value(),
      bucket: rdBucket.value(),
      reportServerUrl: rdReportServerUrl.value()
    }
  }
  return runPackageDeps
}

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
      "POST run_package": "Runs an analysis package on the researcher's MicroVM, launching or reusing one (portal-only, header bearer required)",
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
api.post("/run_package", requireHeaderBearer, (req, res) => makeRunPackage(researcherDashboardDeps())(req, res))

// Takes a standard express app and transforms it into a firebase function
// handler that behaves 'correctly' with respect to trailing slashes.
const wrappedApi = functions
  // The AWS keys are the researcher dashboard's launcher user, reached only by
  // run_package. Secrets are declared per function, so every route here runs with them
  // in its environment.
  .runWith({ secrets: [bearerToken, awsKey, awsSecretKey], timeoutSeconds: 300 })   // STORY 3: headroom for a slow bulk page; ceiling, not a cost floor
  .https.onRequest( (req: express.Request, res: express.Response) =>  {
    if (!req.path) {
      req.url = `/${req.url}` // prepend '/' to keep query params if any
    }
    api(req, res)
  })

module.exports = {
  api: wrappedApi,
  createSyncDocAfterAnswerWritten,
  monitorSyncDocCount,
  syncToS3AfterSyncDocWritten,
  submitTask,
  taskWorker,
  chatTutorOnWrite, // per-page AI chat tutor trigger
}
