// Drive one pipeline run: select a scenario, submit the job to the emulator's
// submitTask, poll the job document, and check the outcome against what the
// scenario expects. Requires the emulator suite, the stub portal, and a prior
// seed.js run.

const fs = require("fs");
const { createHash } = require("crypto");
const {
  CONTEXT, REQUEST, FLEX_PROGRAM, assertLoopbackEmulator, PROJECT_ID,
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

// ⚠️ The ARM, which is what the document holds, rather than a class word composed from it. Composing
// one asserted nothing: both sides came out of harness constants, so the check passed while printing
// a class that need not exist (spring's composed "fl-spring-2026-origin-shark" never has: spring
// appends no suffix and enrols by authored class id, into im-done-shark-202). What the pipeline
// computed is observed by the enrolment assertion below, which reads what actually reached the stub.
const readAssignedArm = async (scenario, context) => {
  const snap = await admin.firestore()
    .doc(`sources/${context.source_key}/jobs-task-data/${assignmentDocId(scenario, context)}`).get();
  if (!snap.exists) {
    return undefined;
  }
  for (const stratum of Object.values(snap.data().strata || {})) {
    const arm = stratum.users && stratum.users[context.platform_user_id];
    if (arm) {
      return arm;
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
  if (expect.status === "success" && expect.assignedArm) {
    const assigned = await readAssignedArm(scenario, context);
    classOk = assigned === expect.assignedArm;
    console.log(`assigned arm: ${assigned} (expected ${expect.assignedArm})`);
  } else if (expect.status === "success" && expect.noAssignment) {
    // Asserted, not skipped: the read-back is available either way, so "no assignment" can be
    // checked as cheaply as it can be declared.
    const assigned = await readAssignedArm(scenario, context);
    classOk = assigned === undefined;
    console.log(`assigned arm: ${assigned === undefined ? "(none, as expected)" : assigned} (this stage makes no assignment)`);
  } else if (expect.status === "success") {
    // ⚠️ Neither declared. Failing here rather than skipping quietly, because the two branches
    // above are opt-in: a success scenario that declares neither would otherwise report PASS while
    // verifying nothing beyond its completion text, and nothing on screen would say so.
    console.log("(no expect.assignedArm and no expect.noAssignment; declare one)");
    classOk = false;
  }

  // ⚠️ Stringified on both sides, and that is not defensive tidiness: the two enrolling steps
  // disagree on the type they post and the two declaring scenarios disagree on the type they hold.
  // enroll-specified-class posts String(lookup.class.id) against a numeric classes/info fixture,
  // while spring's random-assignment posts an already-string authored class id. A === comparison
  // would pass for one and fail for the other, on the one assertion here that observes a decision
  // the pipeline made rather than restating a harness value.
  //
  // ⚠️ Declaring one or the other is REQUIRED, on the same reasoning as the assignment read-back
  // above, and it matters more here: this is the assertion that observes the pipeline rather than
  // comparing two harness values. A stage scenario added without it would check its completion text
  // and an arm, and nothing about the class the pipeline actually resolved.
  let enrollOk = true;
  if (expect.status === "success" && expect.enrolledClassId !== undefined) {
    const enrolled = readEnrolledClassId();
    enrollOk = String(enrolled) === String(expect.enrolledClassId);
    console.log(`enrolled class id: ${enrolled} (expected ${expect.enrolledClassId})`);
  } else if (expect.status === "success" && expect.noEnrollment) {
    // Also asserted: the record file was deleted before the submit, so its absence is evidence that
    // no add_to_class reached the stub at all, which is what a stage with no enrol step must do.
    const enrolled = readEnrolledClassId();
    enrollOk = enrolled === undefined;
    console.log(`enrolled class id: ${enrolled === undefined ? "(none, as expected)" : enrolled} (this stage enrols nobody)`);
  } else if (expect.status === "success") {
    console.log("(no expect.enrolledClassId and no expect.noEnrollment; declare one)");
    enrollOk = false;
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
