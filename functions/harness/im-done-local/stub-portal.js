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
const {
  PORTS, SCENARIO_FILE, LAST_ENROLL_FILE, ORIGIN_CLASS, DESTINATION_CLASS, STUDY_CONTROL_CLASS,
  TARGET_OFFERING_NAME, FALL_CONTEXTS, FALL_FT_TREATMENT_CLASS, FALL_FLEX_CONTROL_CLASS,
  FALL_FLEX_TREATMENT_CLASS, FALL_FT_REGISTRATION_CLASS, FALL_FLEX_REGISTRATION_CLASS,
} = require("./config");
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

// Model the portal's behaviour rather than trusting the fixture: Portal::Clazz lowercases and
// strips class_word before validation on every save, so a stub that echoes a mixed-case fixture
// asserts a contract the portal does not honour.
const storedClassWord = (word) => String(word).trim().toLowerCase();

// A get_info body. As in the real controller, each offering carries both `url` (the
// offering's own API url) and `external_url` (the activity url), which resolve to
// different fields for a consumer that matches offerings by activity.
// `offerings` is a list, so a class can serve more than one. That is what lets a by-name match
// prove it selected the right offering rather than the only one available.
const classInfoFor = ({ id, word, name }, offerings) => ({
  id,
  uri: `http://localhost/api/v1/classes/${id}`,
  name,
  class_hash: `stub-${storedClassWord(word)}-hash`,
  class_word: storedClassWord(word),
  teachers: [{ id: "http://localhost/users/7", user_id: 7, first_name: "Stub", last_name: "Teacher" }],
  students: [],
  offerings: offerings.map((offering) => ({
    id: offering.id,
    name: offering.name,
    active: true,
    // The study's control subclass holds the curriculum present but locked, which is what the open
    // path exists to undo. get_info renders teacher_visible_offerings, which filters on
    // runnable.archived? and nothing else, so neither flag hides it from the name match.
    locked: !!offering.locked,
    metadata: [],
    url: `http://localhost/api/v1/offerings/${offering.id}`,
    external_url: `http://localhost/activities/${offering.id}`,
  })),
});

const classInfo = classInfoFor(ORIGIN_CLASS, [{ id: 555, name: "Origin Offering" }]);
const destinationClassInfo = classInfoFor(DESTINATION_CLASS, [{ id: 556, name: "Destination Offering" }]);
// Two offerings, mirroring the real study class: the post-test the student launched from and the
// locked curriculum.
const studyControlClassInfo = classInfoFor(STUDY_CONTROL_CLASS, [
  // Its id is the post-test scenario's own resource_link_id, so the class contains the offering the
  // student launched from, as the real study class does, and a correct by-name match must NOT
  // select it.
  //
  // ⚠️ This id is NOT here to exercise the self-target guard, which compares the offering that
  // matched the BLUE target name (id 845) against resource_link_id and never looks at this one.
  // That guard is reached only by open-target-offering.test.ts, from a shape no harness scenario
  // reproduces.
  { id: FALL_CONTEXTS["fall-orange-control"].resource_link_id, name: "Orange Sequence for AI in Math (FLVS 26-27)", locked: false },
  { id: 845, name: TARGET_OFFERING_NAME, locked: true },
]);

const CLASSES_BY_WORD = {
  [storedClassWord(ORIGIN_CLASS.word)]: classInfo,
  [storedClassWord(DESTINATION_CLASS.word)]: destinationClassInfo,
  [storedClassWord(STUDY_CONTROL_CLASS.word)]: studyControlClassInfo,
  [storedClassWord(FALL_FT_TREATMENT_CLASS.word)]: classInfoFor(FALL_FT_TREATMENT_CLASS, []),
  [storedClassWord(FALL_FLEX_CONTROL_CLASS.word)]: classInfoFor(FALL_FLEX_CONTROL_CLASS, []),
  [storedClassWord(FALL_FLEX_TREATMENT_CLASS.word)]: classInfoFor(FALL_FLEX_TREATMENT_CLASS, []),
};

// ⚠️ All THREE identity fields offerings#show serves are per scenario, not just class_word. Making
// only the word scenario-aware would leave a post-test run reporting origin class
// ft-2026-bingler-shark while send-email posts the teacher notification to class 90210, and THE
// SCENARIO WOULD NOT CATCH IT, because send-email's fallback reads the same wrong value from this
// same response: the handoff and the fallback would agree on being wrong.
//
// ⚠️ A SEPARATE map from CLASSES_BY_WORD, and deliberately a superset of it. classes/info serves
// only the words a step looks up BY NAME; offerings#show additionally has to serve the two
// registration classes, which a fall pre-test launches from and which no step ever looks up. Keeping
// one map for both would force the registration words into the classes/info fixture set and make it
// imply the origin is resolved through that endpoint, which is exactly what config.js's comment
// exists to deny.
const ORIGIN_IDENTITY_BY_WORD = {
  ...CLASSES_BY_WORD,
  // No offerings: these are never served through classes/info, so the list is never read.
  [storedClassWord(FALL_FT_REGISTRATION_CLASS.word)]: classInfoFor(FALL_FT_REGISTRATION_CLASS, []),
  [storedClassWord(FALL_FLEX_REGISTRATION_CLASS.word)]: classInfoFor(FALL_FLEX_REGISTRATION_CLASS, []),
};

// Returns undefined for a DECLARED word with no fixture, so the caller can fail loudly. A scenario
// that declares nothing keeps today's shared identity, which is what leaves all the existing
// scenarios unchanged.
const originClassFor = (scenarioName) => {
  const scenario = SCENARIOS[scenarioName];
  const word = scenario && scenario.originClassWord;
  return word ? ORIGIN_IDENTITY_BY_WORD[storedClassWord(word)] : classInfo;
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
// The lookup is case-insensitive because portal_clazzes is charset utf8 with no explicit collation
// (so utf8_general_ci), which is why student self-registration accepts a typed word in any case.
const classesInfoResponse = (behavior, classWord) => {
  if (behavior === "forbidden") {
    return { status: 403, body: punditForbidden };
  }
  const found = CLASSES_BY_WORD[storedClassWord(classWord)];
  return found
    ? { status: 200, body: found }
    : { status: 400, body: errorEnvelope("The requested class was not found") };
};

const lockResponse = (behavior, body) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "notfound":
      return { status: 404, body: errorEnvelope("student not found in the class") };
    case "server_error":
      return { status: 500, body: { error: "Internal Server Error" } };
    default:
      // Echo the request's flags rather than hardcoding them. The real action renders the resulting
      // row, so a hardcoded response would make an unlock's success log report locked:true, a
      // diagnostic that states the opposite of what the step did.
      return { status: 200, body: { active: body.active === "true", locked: body.locked === "true" } };
  }
};

const offeringResponse = (behavior, id, scenarioName) => {
  switch (behavior) {
    case "forbidden":
      return { status: 403, body: punditForbidden };
    case "notfound":
      return { status: 404, body: errorEnvelope("offering not found") };
    case "no_clazz":
      return { status: 200, body: { id, name: "Origin Offering" } };
    case "server_error":
      return { status: 500, body: { error: "Internal Server Error" } };
    default: {
      // ⚠️ NEVER fall back to classInfo here. A scenario whose declared originClassWord has no
      // fixture would then be served the SPRING origin class, resolveOriginClass would publish
      // fl-spring-2026-origin, classifyFallProgram would return undefined, and the run would fail
      // with "unclassifiable origin class word": a pipeline-shaped message for a fixture-shaped
      // fault. A 500 plus this line in terminal 2 names the actual cause.
      const origin = originClassFor(scenarioName);
      if (!origin) {
        console.error(`[stub] scenario "${scenarioName}" declares an originClassWord with no class fixture`);
        return { status: 500, body: errorEnvelope("stub misconfiguration: no class fixture for this scenario's originClassWord") };
      }
      return {
        status: 200,
        body: { id, clazz_id: origin.id, clazz_hash: origin.class_hash, class_word: origin.class_word, name: "Origin Offering", active: true, locked: false },
      };
    }
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
      return { locked: body.locked, active: body.active, user_id: body.user_id };
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
      result = lockResponse(behavior.lock, body);
    } else if (req.method === "GET" && /^\/api\/v1\/offerings\/[^/]+$/.test(path)) {
      route = "offering";
      const id = path.split("/").pop();
      result = offeringResponse(behavior.offering, id, name);
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

    // Record the enrolment so run.js can assert the class the pipeline actually enrolled into, rather
    // than only the arm it stored. Written on every add_to_class, including the failure behaviours, so
    // a stale file from an earlier scenario can never be mistaken for this run's.
    //
    // Non-secret by construction: clazz_id and user_id only, never the Authorization header or the
    // forwarded token. Same masking rule as the request log below it.
    if (route === "enroll") {
      fs.writeFileSync(LAST_ENROLL_FILE, JSON.stringify({
        scenario: name, clazz_id: body.clazz_id, user_id: body.user_id, status: result.status,
      }));
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
