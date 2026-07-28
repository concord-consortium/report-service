// Drive one pipeline run: select a scenario, submit the job to the emulator's
// submitTask, poll the job document, and check the outcome against what the
// scenario expects. Requires the emulator suite, the stub portal, and a prior
// seed.js run.

const fs = require("fs");
const {
  CONTEXT, REQUEST, EXPECTED_CLASS, EMULATOR_HOSTS, PROJECT_ID,
  SUBMIT_URL, RUN_CONTEXT_FILE, SCENARIO_FILE,
} = require("./config");
const { SCENARIOS } = require("./scenarios");

Object.assign(process.env, EMULATOR_HOSTS);
const admin = require("firebase-admin");
admin.initializeApp({ projectId: PROJECT_ID });

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
  const classOk = expect.status !== "success" || (typeof message === "string");

  const pass = statusOk && messageOk && classOk;
  console.log(`\nexpected status=${expect.status}, message includes "${expect.messageIncludes}"`);
  if (expect.failsAt) {
    console.log(`(expected to stop at the ${expect.failsAt} step)`);
  }
  if (expect.status === "success") {
    console.log(`(expected assignment: ${EXPECTED_CLASS})`);
  }
  console.log(pass ? "\nPASS ✓" : "\nFAIL ✗");
  process.exit(pass ? 0 : 1);
};

main().catch((err) => {
  console.error("run failed:", err);
  process.exit(1);
});
