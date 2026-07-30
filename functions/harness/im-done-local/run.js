// Drive one pipeline run: select a scenario, submit the job to the emulator's
// submitTask, poll the job document, and check the outcome against what the
// scenario expects. Requires the emulator suite, the stub portal, and a prior
// seed.js run.

const fs = require("fs");
const { createHash } = require("crypto");
const {
  CONTEXT, REQUEST, DESTINATION_SUFFIX, FLEX_PROGRAM, assertLoopbackEmulator, PROJECT_ID,
  SUBMIT_URL, RUN_CONTEXT_FILE, SCENARIO_FILE, LAST_ENROLL_FILE,
} = require("./config");
const { SCENARIOS } = require("./scenarios");

// Refuse to run if either emulator host is not loopback (guards against touching real Firestore).
assertLoopbackEmulator();
const admin = require("firebase-admin");
admin.initializeApp({ projectId: PROJECT_ID });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const sha256 = (value) => createHash("sha256").update(value).digest("hex");

const pollJob = async (jobPath, timeoutMs = 30000) => {
  const ref = admin.firestore().doc(jobPath);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const snap = await ref.get();
    const info = snap.exists ? snap.data().jobInfo : undefined;
    if (info && ["success", "failure", "cancelled"].includes(info.status)) {
      return info;
    }
    await sleep(400);
  }
  throw new Error(`Timed out waiting for ${jobPath} to complete`);
};

// Two formulas, not one variant of one. Full-time uses the per-class document (which includes the
// launch context, so it is per scenario); flex uses the pooled document, which is keyed on the
// PROGRAM and is therefore shared by every flex scenario that will ever exist.
const assignmentDocId = (scenario, context) => {
  if (scenario.assignmentScope === "pooled") {
    return sha256(`ai4vs-flvs-assignments-pooled|${FLEX_PROGRAM}|${context.interactiveId}|${context.platform_id}`);
  }
  return sha256(`ai4vs-flvs-assignments|${context.interactiveId}|${context.platform_id}|${context.resource_link_id}|${context.context_id}`);
};

// The stored value is an ARM, so the word is derived. Note what that does and does not observe:
// both sides of the comparison are harness values, so this proves the strata-to-class mapping and
// that some enrolment succeeded, not that the pipeline computed the same word. The enrolment
// assertion below is what observes that.
const readAssignedWord = async (scenario, context) => {
  const snap = await admin.firestore()
    .doc(`sources/${context.source_key}/jobs-task-data/${assignmentDocId(scenario, context)}`).get();
  if (!snap.exists) {
    return undefined;
  }
  for (const stratum of Object.values(snap.data().strata || {})) {
    const arm = stratum.users && stratum.users[context.platform_user_id];
    if (arm) {
      return `${scenario.originClassWord}${DESTINATION_SUFFIX[arm]}`;
    }
  }
  return undefined;
};

// The pipeline resolved a class WORD to a class ID and enrolled into it. Asserting the id is what
// makes a scenario observe that decision; the assignment read-back above only observes the arm, and
// recomposes the word from harness constants.
const readEnrolledClassId = () => {
  if (!fs.existsSync(LAST_ENROLL_FILE)) {
    return undefined;
  }
  return JSON.parse(fs.readFileSync(LAST_ENROLL_FILE, "utf8")).clazz_id;
};

const main = async () => {
  const scenarioName = process.argv[2] || "happy";
  const scenario = SCENARIOS[scenarioName];
  if (!scenario) {
    console.error(`Unknown scenario "${scenarioName}". Available:\n  ${Object.keys(SCENARIOS).join("\n  ")}`);
    process.exit(2);
  }
  if (!fs.existsSync(RUN_CONTEXT_FILE)) {
    console.error(`Missing ${RUN_CONTEXT_FILE}. Run: node seed.js`);
    process.exit(2);
  }
  const { token } = JSON.parse(fs.readFileSync(RUN_CONTEXT_FILE, "utf8"));

  // The stub reads this before each request.
  fs.writeFileSync(SCENARIO_FILE, scenarioName);
  // Drop any record left by the previous scenario, so a stale one cannot satisfy this run.
  fs.rmSync(LAST_ENROLL_FILE, { force: true });

  const request = { ...REQUEST, ...(scenario.request || {}) };
  const context = { ...CONTEXT, ...(scenario.context || {}) };

  console.log(`\n=== scenario: ${scenarioName} ===`);
  console.log(scenario.describe);

  const res = await fetch(SUBMIT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ request, context }),
  });
  if (!res.ok) {
    console.error(`submitTask returned ${res.status}: ${await res.text()}`);
    process.exit(1);
  }
  const jobInfo = await res.json();
  const jobPath = `sources/${context.source_key}/jobs/${jobInfo.id}`;
  console.log(`submitted ${jobPath}, waiting for completion…`);

  const final = await pollJob(jobPath);
  const message = final.result && final.result.message;

  console.log(`\noutcome: ${final.status}`);
  console.log(`message: ${message}`);

  const expect = scenario.expect;
  const statusOk = final.status === expect.status;
  const messageOk = typeof message === "string" && message.includes(expect.messageIncludes);

  let classOk = true;
  if (expect.status === "success" && expect.assignedClassWord) {
    const assigned = await readAssignedWord(scenario, context);
    classOk = assigned === expect.assignedClassWord;
    console.log(`assigned class word: ${assigned} (expected ${expect.assignedClassWord})`);
  } else if (expect.status === "success" && expect.noAssignment) {
    console.log("(this stage makes no assignment; no read-back)");
  }

  // ⚠️ Stringified on both sides, and that is not defensive tidiness: the two enrolling steps
  // disagree on the type they post and the two declaring scenarios disagree on the type they hold.
  // enroll-specified-class posts String(lookup.class.id) against a numeric classes/info fixture,
  // while spring's random-assignment posts an already-string authored class id. A === comparison
  // would pass for one and fail for the other, on the one assertion here that observes a decision
  // the pipeline made rather than restating a harness value.
  let enrollOk = true;
  if (expect.status === "success" && expect.enrolledClassId !== undefined) {
    const enrolled = readEnrolledClassId();
    enrollOk = String(enrolled) === String(expect.enrolledClassId);
    console.log(`enrolled class id: ${enrolled} (expected ${expect.enrolledClassId})`);
  }

  const pass = statusOk && messageOk && classOk && enrollOk;
  console.log(`\nexpected status=${expect.status}, message includes "${expect.messageIncludes}"`);
  if (expect.failsAt) {
    console.log(`(expected to stop at the ${expect.failsAt} step)`);
  }
  console.log(pass ? "\nPASS ✓" : "\nFAIL ✗");
  process.exit(pass ? 0 : 1);
};

main().catch((err) => {
  console.error("run failed:", err);
  process.exit(1);
});
