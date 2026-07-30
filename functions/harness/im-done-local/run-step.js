// Drive one pipeline step directly against the stub portal, with no emulator and no
// seeded Firestore (the steps driven here read neither). It builds a StepContext by
// hand, runs the compiled step twice against the same context, and checks each run's
// StepResult against what the scenario expects. The scenario picks the step.
//
// Running twice is what covers re-entry: the second run sees a populated token cache
// and the first run's result accumulated in stepResults, as the real runner leaves them.
//
// Requires a prior `npm run build`: unlike run.js, this driver imports compiled step
// code from lib/.

const fs = require("fs");
const { PLATFORM_ID, CONTEXT, SCENARIO_FILE } = require("./config");
const { SCENARIOS } = require("./scenarios");

const LIB = `${__dirname}/../../lib`;

// Per-scenario step selection. A scenario names the compiled module, the export and the pipeline
// entry name its result is written back under; the defaults keep the enroll scenarios unchanged.
const stepFor = (scenario) => ({
  module: `${LIB}/tasks/ai4vs-flvs/${scenario.stepModule || "enroll-specified-class"}.js`,
  exportName: scenario.stepExport || "enrollSpecifiedClass",
  name: scenario.stepName || "enroll-specified-class",
});

// The mint is OIDC-authed; the emulator path sends this env token instead of asking
// GoogleAuth for a real one. The stub does not inspect either value.
process.env.FUNCTIONS_EMULATOR = "true";
process.env.PORTAL_OIDC_TOKEN = process.env.PORTAL_OIDC_TOKEN || "stub-oidc-token";

// Seed the handoff a step takes its input from. A step that reads stepResults rather than a request
// param would otherwise fail its absent-handoff check before reaching anything the scenario tests.
const seedStepResults = (scenario) =>
  scenario.seedOriginClassWord
    ? {
        "resolve-origin-class": {
          success: true,
          summary: `Origin class ${scenario.seedOriginClassWord}`,
          output: { originClassWord: scenario.seedOriginClassWord },
        },
      }
    : {};

const buildContext = (scenario, tokenCache, stepResults) => ({
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
      request: {
        task: "ai4vs-flvs",
        pilot: scenario.pilot || "fall-2026-green",
        target_class_word: scenario.targetClassWord,
      },
      createdAt: Date.now(),
    },
  },
  firebaseJwt: "stub-forwarded-firebase-token",
  stepResults,
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
  const step = stepFor(scenario);
  if (!fs.existsSync(step.module)) {
    console.error(`Missing ${step.module}. Run: npm run build`);
    process.exit(2);
  }

  const handler = require(step.module)[step.exportName];
  if (typeof handler !== "function") {
    console.error(`${step.module} has no export "${step.exportName}"`);
    process.exit(2);
  }
  const { createPortalTokenCache } = require(`${LIB}/tasks/portal-api.js`);

  // The stub reads this before each request.
  fs.writeFileSync(SCENARIO_FILE, scenarioName);

  console.log(`\n=== scenario: ${scenarioName} ===`);
  console.log(scenario.describe);
  console.log(`step: ${step.name}`);
  if (scenario.targetClassWord) {
    console.log(`target_class_word: ${scenario.targetClassWord}`);
  }
  if (scenario.seedOriginClassWord) {
    console.log(`seeded originClassWord: ${scenario.seedOriginClassWord}`);
  }

  const context = buildContext(scenario, createPortalTokenCache(), seedStepResults(scenario));

  let pass = true;
  for (const run of [1, 2]) {
    console.log(`\nrun ${run}: entering with stepResults [${Object.keys(context.stepResults).join(", ")}]`);
    const result = await handler(context);
    // Write the result back the way index.ts does, so run 2 is a real re-entry with accumulated
    // state rather than a repeat of run 1's inputs. That includes the runner's guard: index.ts
    // records a result only after checking success and returns early otherwise, so a failure
    // scenario's run 2 must not enter carrying a key the real pipeline could never have produced.
    if (result.success) {
      context.stepResults[step.name] = result;
    }
    const { statusOk, textOk, text } = checkRun(result, scenario.expect);
    console.log(`run ${run}: success=${result.success}`);
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
