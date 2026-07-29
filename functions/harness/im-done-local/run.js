// Drive one pipeline run: select a scenario, submit the job to the emulator's
// submitTask, poll the job document, and check the outcome against what the
// scenario expects. Requires the emulator suite, the stub portal, and a prior
// seed.js run.

const fs = require("fs");
const { createHash } = require("crypto");
const {
  CONTEXT, REQUEST, EXPECTED_CLASS, assertLoopbackEmulator, PROJECT_ID,
  SUBMIT_URL, RUN_CONTEXT_FILE, SCENARIO_FILE,
} = require("./config");
const { SCENARIOS } = require("./scenarios");

// Refuse to run if either emulator host is not loopback (guards against touching real Firestore).
assertLoopbackEmulator();
const admin = require("firebase-admin");
admin.initializeApp({ projectId: PROJECT_ID });

const CLASS_BY_ASSIGNMENT = { treatment: "FL-spring-2026-GATOR", control: "FL-spring-2026-SHARK" };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

// Read the class this student was actually assigned to from the persisted
// assignment doc (the same sha256 key random-assignment writes), so the happy
// path verifies the end-to-end enrollment rather than just the completion text.
const readAssignedClass = async () => {
  const docId = createHash("sha256")
    .update(`ai4vs-flvs-assignments|${CONTEXT.interactiveId}|${CONTEXT.platform_id}|${CONTEXT.resource_link_id}|${CONTEXT.context_id}`)
    .digest("hex");
  const snap = await admin.firestore().doc(`sources/${CONTEXT.source_key}/jobs-task-data/${docId}`).get();
  if (!snap.exists) {
    return undefined;
  }
  const strata = snap.data().strata || {};
  for (const stratum of Object.values(strata)) {
    const assignment = stratum.users && stratum.users[CONTEXT.platform_user_id];
    if (assignment) {
      return CLASS_BY_ASSIGNMENT[assignment];
    }
  }
  return undefined;
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

  console.log(`\n=== scenario: ${scenarioName} ===`);
  console.log(scenario.describe);

  const res = await fetch(SUBMIT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ request: REQUEST, context: CONTEXT }),
  });
  if (!res.ok) {
    console.error(`submitTask returned ${res.status}: ${await res.text()}`);
    process.exit(1);
  }
  const jobInfo = await res.json();
  const jobPath = `sources/${CONTEXT.source_key}/jobs/${jobInfo.id}`;
  console.log(`submitted ${jobPath}, waiting for completion…`);

  const final = await pollJob(jobPath);
  const message = final.result && final.result.message;

  console.log(`\noutcome: ${final.status}`);
  console.log(`message: ${message}`);

  const expect = scenario.expect;
  const statusOk = final.status === expect.status;
  const messageOk = typeof message === "string" && message.includes(expect.messageIncludes);

  let classOk = true;
  if (expect.status === "success") {
    const assignedClass = await readAssignedClass();
    classOk = assignedClass === EXPECTED_CLASS;
    console.log(`assigned class: ${assignedClass} (expected ${EXPECTED_CLASS})`);
  }

  const pass = statusOk && messageOk && classOk;
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
