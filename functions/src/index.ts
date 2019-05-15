import * as functions from "firebase-functions"
const cors = require("cors")

// Without these next two lines we see this error:
// The Firebase Admin module has not been initialized early enough.
// Make sure you run "admin.initializeApp()" outside of any function …
const admin = require('firebase-admin');
admin.initializeApp();

import express from "express"

/* Express with CORS & automatic trailing '/' solution */
const app = express()
app.use(cors({ origin: true }))
app.get("*", (request, response) => {
  response.send(
    "Hello from Express w/ cors. XYZZY. No trailing '/' required..."
  )
})

// not as clean, but a better endpoint to consume
const api = functions.https.onRequest((request, response) => {
  if (!request.path) {
    request.url = `/${request.url}` // prepend '/' to keep query params if any
  }
  return app(request, response)
})

module.exports = {
  api
}

