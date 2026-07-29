// A stand-in for the RIGSE-352 portal for local, fully-offline runs of the
// "I'm Done" pipeline. Response bodies mirror the real controllers
// (oidc_mint / students / offerings / emails / classes) so report-service's
// classifier is exercised against the actual wire shapes. The behavior of each
// endpoint is chosen by the active scenario (see scenarios.js).
//
// Secrets are never logged: the Authorization header, the forwarded
// firebase_token, and the minted token are masked or omitted.

const http = require("http");
const fs = require("fs");
const { PORTS, SCENARIO_FILE, ORIGIN_CLASS, DESTINATION_CLASS } = require("./config");
const { SCENARIOS, OK } = require("./scenarios");

let mintCounter = 0;

const errorEnvelope = (message, details) => {
  const body = { success: false, response_type: "ERROR", message };
  if (details) {
    body.details = details;
  }
  return body;
};

const punditForbidden = { success: false, message: "Not authorized" };

// A get_info body. As in the real controller, each offering carries both `url` (the
// offering's own API url) and `external_url` (the activity url), which resolve to
// different fields for a consumer that matches offerings by activity.
const classInfoFor = ({ id, word, name }, offering) => ({
  id,
  uri: `http://localhost/api/v1/classes/${id}`,
  name,
  class_hash: `stub-${word}-hash`,
  class_word: word,
  teachers: [{ id: "http://localhost/users/7", user_id: 7, first_name: "Stub", last_name: "Teacher" }],
  students: [],
  offerings: [{
    id: offering.id,
    name: offering.name,
    active: true,
    locked: false,
    metadata: [],
    url: `http://localhost/api/v1/offerings/${offering.id}`,
    external_url: `http://localhost/activities/${offering.id}`,
  }],
});

const classInfo = classInfoFor(ORIGIN_CLASS, { id: 555, name: "Origin Offering" });
const destinationClassInfo = classInfoFor(DESTINATION_CLASS, { id: 556, name: "Destination Offering" });

const CLASSES_BY_WORD = {
  [ORIGIN_CLASS.word]: classInfo,
  [DESTINATION_CLASS.word]: destinationClassInfo,
};

const activeBehavior = () => {
  let name = process.env.SCENARIO || "happy";
  try {
    const fromFile = fs.readFileSync(SCENARIO_FILE, "utf8").trim();
    if (fromFile) {
      name = fromFile;
    }
  } catch {
    // no scenario file yet; fall back to env/default
  }
  const scenario = SCENARIOS[name];
  return { name, behavior: scenario ? scenario.behavior : OK };
};

const mask = (auth) => {
  if (typeof auth !== "string") {
    return "(none)";
  }
  const token = auth.replace(/^Bearer\s+/i, "");
  // Log presence and length only, never any of the token's content.
  return `Bearer <len=${token.length}>`;
};

// { status, body } for a mint request under the given behavior.
const mintResponse = (behavior, body) => {
  switch (behavior) {
    case "expired":
      return { status: 422, body: errorEnvelope("Forwarded Firebase token invalid: expired", { reason: "expired" }) };
    case "signature":
      return { status: 422, body: errorEnvelope("Forwarded Firebase token invalid: signature", { reason: "signature" }) };
    case "no_shared_teacher":
      return { status: 422, body: errorEnvelope("No teacher is shared between the origin class and the requested class") };
    case "bad_token_type":
      return { status: 422, body: errorEnvelope('token_type must be "learner" or "teacher"') };
    case "unauthorized":
      return { status: 403, body: errorEnvelope("This OIDC client is not permitted to mint scoped tokens") };
    case "unauthenticated":
      return { status: 401, body: errorEnvelope("You must be logged in to use this endpoint") };
    default: {
      mintCounter += 1;
      const scope = body && body.class_id !== undefined ? `class-${body.class_id}` : "origin";
      return { status: 201, body: { token: `stub-minted-${scope}-${mintCounter}` } };
    }
  }
};

const enrollResponse = (behavior) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "nonsuccess":
      return { status: 200, body: { success: false } };
    default:
      return { status: 200, body: { success: true } };
  }
};

// classes#info keys its response on the requested class_word; an unknown word gets the
// real controller's error('The requested class was not found'), which defaults to 400.
const classesInfoResponse = (behavior, classWord) => {
  if (behavior === "forbidden") {
    return { status: 403, body: punditForbidden };
  }
  const found = CLASSES_BY_WORD[classWord];
  return found
    ? { status: 200, body: found }
    : { status: 400, body: errorEnvelope("The requested class was not found") };
};

const lockResponse = (behavior) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "notfound":
      return { status: 404, body: errorEnvelope("student not found in the class") };
    case "server_error":
      return { status: 500, body: { error: "Internal Server Error" } };
    default:
      return { status: 200, body: { active: true, locked: true } };
  }
};

const offeringResponse = (behavior, id) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "notfound":
      return { status: 404, body: errorEnvelope("offering not found") };
    case "no_clazz":
      return { status: 200, body: { id, name: "Origin Offering" } };
    case "server_error":
      return { status: 500, body: { error: "Internal Server Error" } };
    default:
      return {
        status: 200,
        body: { id, clazz_id: classInfo.id, clazz_hash: classInfo.class_hash, class_word: classInfo.class_word, name: "Origin Offering", active: true, locked: false },
      };
  }
};

const sendResponse = (behavior) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "no_teacher_email":
      return { status: 422, body: errorEnvelope("No teacher of the class has an email address configured") };
    case "delivery":
      return { status: 502, body: errorEnvelope("Email delivery failed: Net::SMTPError: connection refused") };
    case "nonsuccess":
      return { status: 200, body: { success: false } };
    default:
      return { status: 200, body: { success: true, message: "Email sent" } };
  }
};

const parseBody = (raw, contentType) => {
  if (!raw) {
    return {};
  }
  if ((contentType || "").includes("application/json")) {
    try {
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }
  if ((contentType || "").includes("application/x-www-form-urlencoded")) {
    return Object.fromEntries(new URLSearchParams(raw));
  }
  return {};
};

// Non-secret fields worth showing per endpoint.
const logFields = (route, body, url) => {
  switch (route) {
    case "mint":
      return { token_type: body.token_type, class_id: body.class_id, description: body.description };
    case "classes-info":
      return { class_word: url.searchParams.get("class_word") };
    case "enroll":
      return { user_id: body.user_id, clazz_id: body.clazz_id };
    case "lock":
      return { locked: body.locked, user_id: body.user_id };
    case "send":
      return { class_id: body.class_id, subject: body.subject };
    default:
      return {};
  }
};

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks).toString("utf8");
    const body = parseBody(raw, req.headers["content-type"]);
    const { name, behavior } = activeBehavior();
    const url = new URL(req.url, "http://localhost");
    const path = url.pathname;

    let route = "unknown";
    let result = { status: 404, body: errorEnvelope("not found", undefined) };

    if (req.method === "POST" && path === "/api/v1/jwt/oidc_mint") {
      route = "mint";
      if (behavior.mint === "network") {
        console.log(`[stub] mint -> DROP CONNECTION (scenario=${name})`);
        req.destroy();
        res.destroy();
        return;
      }
      result = mintResponse(behavior.mint, body);
    } else if (req.method === "POST" && path === "/api/v1/students/add_to_class") {
      route = "enroll";
      result = enrollResponse(behavior.enroll);
    } else if (req.method === "PUT" && /\/api\/v1\/offerings\/[^/]+\/update_student_metadata$/.test(path)) {
      route = "lock";
      if (behavior.lock === "network") {
        console.log(`[stub] lock -> DROP CONNECTION (scenario=${name})`);
        req.destroy();
        res.destroy();
        return;
      }
      result = lockResponse(behavior.lock);
    } else if (req.method === "GET" && /^\/api\/v1\/offerings\/[^/]+$/.test(path)) {
      route = "offering";
      const id = path.split("/").pop();
      result = offeringResponse(behavior.offering, id);
    } else if (req.method === "POST" && path === "/api/v1/emails/send_class_teachers") {
      route = "send";
      result = sendResponse(behavior.send);
    } else if (req.method === "GET" && path === "/api/v1/classes/info") {
      // Class-word resolution for the fall pipelines.
      route = "classes-info";
      result = classesInfoResponse(behavior.classes, url.searchParams.get("class_word"));
    } else if (req.method === "GET" && /^\/api\/v1\/classes\/[^/]+$/.test(path)) {
      route = "classes-show";
      result = { status: 200, body: classInfo };
    }

    const fields = logFields(route, body, url);
    const fieldStr = Object.keys(fields).length ? ` ${JSON.stringify(fields)}` : "";
    console.log(`[stub] ${req.method} ${path} -> ${result.status} [${route}] auth=${mask(req.headers.authorization)}${fieldStr}`);

    res.writeHead(result.status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(result.body));
  });
});

server.listen(PORTS.stub, "127.0.0.1", () => {
  console.log(`[stub] portal listening on http://localhost:${PORTS.stub} (scenario file: ${SCENARIO_FILE})`);
  console.log(`[stub] active scenario: ${activeBehavior().name}`);
});
