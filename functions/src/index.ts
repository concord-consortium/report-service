import express from "express"
import cors from "cors"
import admin from "firebase-admin"
import * as functions from "firebase-functions"

import bearerTokenAuth from "./middleware/bearer-token-auth"
import responseMethods from "./middleware/response-methods"

import importRun from "./api/import-run"
import importStructure from "./api/import-structure"
import moveStudentWork from "./api/move-student-work"
import getResource from "./api/get-resource"

admin.initializeApp();

const api = express()
api.use(cors({ origin: true }))
api.use(responseMethods)
api.use(bearerTokenAuth)
api.get("/", (req, res) => {
  res.success({
    description: "Report service API",
    methods: {
      "POST import_run": "Imports a run, requires a bearer token",
      "POST import_structure": "Imports the structure, requires a bearer token",
      "POST move_student_work": "Moves a students work from one class to another, requires a bearer token.",
      "GET resource?source=<SOURCE>&url=<URL>": "Returns a resource under source with given url"
    }
  })
})
api.post("/import_run", importRun)
api.post("/import_structure", importStructure)
api.post("/move_student_work", moveStudentWork)
api.get("/resource", getResource)

// Takes a standard express app and transforms it into a firebase function
// handler that behaves 'correctly' with respect to trailing slashes.
const wrappedApi = functions.https.onRequest( (req: express.Request, res: express.Response) =>  {
  if (!req.path) {
    req.url = `/${req.url}` // prepend '/' to keep query params if any
  }
  api(req, res)
})

module.exports = {
  api: wrappedApi
}
