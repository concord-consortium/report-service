import express from "express"
import * as functions from "firebase-functions"

// extracted from https://raw.githubusercontent.com/tkellen/js-express-bearer-token/master/index.js

export default function (req: express.Request, res: express.Response, next: express.NextFunction) {
  let clientBearerToken: string|null = null;

  // no bearer token required for index page, it is the documentation
  if (req.path === "/") {
    next()
    return
  }

  const authConfig = functions.config().auth
  const serverBearerToken = authConfig && authConfig.bearer_token
  if (!serverBearerToken) {
    res.error("No bearer_token set in Firebase auth config!", 500)
    return
  }

  if (req.query && req.query.bearer) {
    clientBearerToken = req.query.bearer;
  }
  else if (req.body && req.body.bearer) {
    clientBearerToken = req.body.bearer;
  }
  else if (req.headers.authorization) {
    const parts = req.headers.authorization.split(" ");
    if ((parts.length === 2) && (parts[0] === "Bearer")) {
      clientBearerToken = parts[1];
    }
  }

  if (!clientBearerToken) {
    res.error("No Bearer header found in request!", 400)
    return
  }

  if (clientBearerToken !== serverBearerToken) {
    res.error("Incorrect bearer token value!", 401)
    return
  }

  next()
}