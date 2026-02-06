import express from "express"
import { defineSecret } from "firebase-functions/params"

// extracted from https://raw.githubusercontent.com/tkellen/js-express-bearer-token/master/index.js

export const bearerToken = defineSecret("AUTH_BEARER_TOKEN");

export default function (req: express.Request, res: express.Response, next: express.NextFunction) {
  let clientBearerToken: string|null = null;

  // no bearer token required for index page, it is the documentation
  if (req.path === "/") {
    next()
    return
  }

  const serverBearerToken = bearerToken.value()
  if (!serverBearerToken) {
    res.error(500, "No AUTH_BEARER_TOKEN secret set!")
    return
  }

  if (req.query && req.query.bearer && typeof req.query.bearer === "string") {
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
    res.error(400, "No bearer found in request header, body, or params")
    return
  }

  if (clientBearerToken !== serverBearerToken) {
    res.error(401, "Incorrect bearer token value!")
    return
  }

  next()
}