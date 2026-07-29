// Drive the enroll-specified-class step directly against the stub portal, with no
// emulator and no seeded Firestore (the step reads neither). It builds a StepContext by
// hand, runs the compiled step twice against the same context, and checks each run's
// StepResult against what the scenario expects.
//
// Running the step twice with one token cache is what makes the re-invocation safe:
// the second run re-resolves the same class word and reuses both cached tokens.
//
// Requires a prior `npm run build`: unlike run.js, this driver imports compiled step
// code from lib/.

const fs = require("fs");
const { PLATFORM_ID, CONTEXT, SCENARIO_FILE } = require("./config");
const { SCENARIOS } = require("./scenarios");

const LIB = `${__dirname}/../../lib`;
const COMPILED_STEP = `${LIB}/tasks/ai4vs-flvs/enroll-specified-class.js`;

// The mint is OIDC-authed; the emulator path sends this env token instead of asking
// GoogleAuth for a real one. The stub does not inspect either value.
process.env.FUNCTIONS_EMULATOR = "true";
process.env.PORTAL_OIDC_TOKEN = process.env.PORTAL_OIDC_TOKEN || "stub-oidc-token";

const buildContext = (targetClassWord, tokenCache) => ({
  jobPath: `sources/${CONTEXT.source_key}/jobs/run-step-local`,
  jobDoc: {
    platform_id: PLATFORM_ID,
    platform_user_id: CONTEXT.platform_user_id,
    resource_link_id: CONTEXT.resource_link_id,
    source_key: CONTEXT.source_key,
    jobInfo: {
      version: 1,
      id: "run-step-local",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-fulltime", target_class_word: targetClassWord },
      createdAt: Date.now(),
    },
  },
  firebaseJwt: "stub-forwarded-firebase-token",
  stepResults: {},
  tokenCache,
  // The step calls the portal at portalOrigin, never at the raw platform_id; the
  // consuming pipeline's validatePortalHost gate is what produces this value.
  portalOrigin: PLATFORM_ID,
});

const checkRun = (result, expect) => {
  const statusOk = result.success === (expect.status === "success");
  const text = expect.status === "success" ? result.summary : result.message;
  const expected = expect.summaryIncludes || expect.messageIncludes;
  const textOk = typeof text === "string" && text.includes(expected);
  return { statusOk, textOk, text };
};

const main = async () => {
  const scenarioName = process.argv[2] || "enroll-happy";
  const scenario = SCENARIOS[scenarioName];
  const stepScenarios = Object.keys(SCENARIOS).filter((name) => SCENARIOS[name].driver === "run-step");
  if (!scenario || scenario.driver !== "run-step") {
    console.error(`Unknown step scenario "${scenarioName}". Available:\n  ${stepScenarios.join("\n  ")}`);
    process.exit(2);
  }
  if (!fs.existsSync(COMPILED_STEP)) {
    console.error(`Missing ${COMPILED_STEP}. Run: npm run build`);
    process.exit(2);
  }

  const { enrollSpecifiedClass } = require(COMPILED_STEP);
  const { createPortalTokenCache } = require(`${LIB}/tasks/portal-api.js`);

  // The stub reads this before each request.
  fs.writeFileSync(SCENARIO_FILE, scenarioName);

  console.log(`\n=== scenario: ${scenarioName} ===`);
  console.log(scenario.describe);
  console.log(`target_class_word: ${scenario.targetClassWord}`);

  const context = buildContext(scenario.targetClassWord, createPortalTokenCache());

  let pass = true;
  for (const run of [1, 2]) {
    const result = await enrollSpecifiedClass(context);
    const { statusOk, textOk, text } = checkRun(result, scenario.expect);
    console.log(`\nrun ${run}: success=${result.success}`);
    console.log(`run ${run}: ${scenario.expect.status === "success" ? "summary" : "message"}: ${text}`);
    pass = pass && statusOk && textOk;
  }

  const expected = scenario.expect.summaryIncludes || scenario.expect.messageIncludes;
  console.log(`\nexpected success=${scenario.expect.status === "success"} on both runs, text includes "${expected}"`);
  console.log(pass ? "\nPASS ✓" : "\nFAIL ✗");
  process.exit(pass ? 0 : 1);
};

main().catch((err) => {
  console.error("run-step failed:", err);
  process.exit(1);
});
