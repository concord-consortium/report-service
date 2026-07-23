import express from "express";

// The shared bearer-token-auth already ran and authenticated. This per-route guard rejects any request that
// carried the bearer as a query param or body value — in ANY form (scalar/array/object) via a key-existence
// check. It enforces header-only usage for this route (401 on query/body bearer), keeping the token out of
// app-level body logs; it cannot scrub a `?bearer=` the upstream proxy already logged (a proxy-layer concern).
export default function requireHeaderBearer(req: express.Request, res: express.Response, next: express.NextFunction) {
  const inQuery = req.query && Object.prototype.hasOwnProperty.call(req.query, "bearer");
  const inBody = req.body && typeof req.body === "object" && Object.prototype.hasOwnProperty.call(req.body, "bearer");
  if (inQuery || inBody) {
    res.error(401, "This route requires the Authorization: Bearer header; query/body bearer is not accepted.");
    return;
  }
  next();
}
