import express from "express"

import * as functions from "firebase-functions"

type IReqHandler = (req: express.Request, resp: express.Response) => void

// Takes a standard express app and transforms it into a firebase function
// handler that behaves 'correctly' with respect to trailing slashes.
const WrapExpressApp = (expressApp: IReqHandler) => {
  const wrapped = functions.https.onRequest( (request: express.Request, response: express.Response) =>  {
    if (!request.path) {
      request.url = `/${request.url}` // prepend '/' to keep query params if any
    }
    return expressApp(request, response)
  })
  return wrapped;
}

 export default WrapExpressApp
