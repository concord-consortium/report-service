// Shared configuration for the local "I'm Done" pipeline harness.
// All three scripts (stub-portal, seed, run) import this so they agree on
// ports, identifiers, and the demographic answers that drive the run.

const PROJECT_ID = "report-service-dev";
const REGION = "us-central1";

const PORTS = {
  functions: 5001,
  firestore: 9090,
  auth: 9099,
  // The Firebase Emulator Hub reserves 4400/4500/9150, so keep the stub clear of them.
  stub: 4488,
};

// The stub portal listens on a loopback host so validatePortalHost's
// emulator-only http carve-out accepts it (localhost must also be listed in
// functions/.env.local under TRUSTED_PORTAL_HOSTS).
const PLATFORM_ID = `http://localhost:${PORTS.stub}`;

const SUBMIT_URL =
  `http://127.0.0.1:${PORTS.functions}/${PROJECT_ID}/${REGION}/submitTask`;

const EMULATOR_HOSTS = {
  FIRESTORE_EMULATOR_HOST: `127.0.0.1:${PORTS.firestore}`,
  FIREBASE_AUTH_EMULATOR_HOST: `127.0.0.1:${PORTS.auth}`,
  GCLOUD_PROJECT: PROJECT_ID,
};

// Point the Admin SDK at the emulator and refuse to run if either emulator host
// is not loopback, so a bad edit to the hosts above can never write to real
// Firestore. Both scripts that initialize the Admin SDK (seed.js, run.js) call this.
const assertLoopbackEmulator = () => {
  Object.assign(process.env, EMULATOR_HOSTS);
  for (const host of [process.env.FIRESTORE_EMULATOR_HOST, process.env.FIREBASE_AUTH_EMULATOR_HOST]) {
    if (!/^(127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(host)) {
      console.error(`Refusing to run: ${host} is not a loopback emulator host.`);
      process.exit(1);
    }
  }
};

// The classes the stub's classes/info serves, keyed by class word. The origin class is the
// one the spring pipeline's offering belongs to; the destination is the one an authored
// (or handed-off) class word resolves to, with a deliberately distinct id and name so a
// run can tell the two apart.
// The words are lowercase because that is what the portal stores: Portal::Clazz downcases and
// strips class_word before validation on every save. `name` keeps its display casing, since the
// portal lowercases the word only and `name` is what send-email renders.
const ORIGIN_CLASS = { id: 90210, word: "fl-spring-2026-origin", name: "FL-spring-2026-origin" };
const DESTINATION_CLASS = { id: 30001, word: "ft-fall-2026-a", name: "FT-fall-2026-A" };

// One participating student and its launch context.
const CONTEXT = {
  source_key: "im-done-local",
  platform_id: PLATFORM_ID,
  platform_user_id: "im-done-student-1",
  context_id: "im-done-ctx-1",
  resource_link_id: "im-done-offering-1",
  interactiveId: "im-done-interactive-1",
  user_type: "learner",
};

const REQUEST = {
  task: "ai4vs-flvs",
  pilot: "spring-2026",
  min_completed_questions: 4,
  treatment_class_id: "im-done-gator-101",
  control_class_id: "im-done-shark-202",
};

// Demographic answers for the strata Female|White|High|Mod1, which the
// spring assignment table maps to control -> FL-spring-2026-SHARK.
const ANSWERS = [
  {
    key: "gender",
    prompt: "<p>What is your sex?</p>",
    choices: [
      { id: "c1", content: "Female" },
      { id: "c2", content: "Male" },
      { id: "c3", content: "Prefer not to answer" },
    ],
    selectedChoiceIds: ["c1"],
  },
  {
    key: "grade",
    prompt: "<p>What grade are you in?</p>",
    choices: [
      { id: "g9", content: "9th Grade" },
      { id: "g10", content: "10th Grade" },
      { id: "g11", content: "11th Grade" },
      { id: "g12", content: "12th Grade" },
      { id: "gO", content: "Other" },
    ],
    selectedChoiceIds: ["g10"],
  },
  {
    key: "module",
    prompt: "<p>Which Algebra 1 module are you currently working on?</p>",
    choices: [
      { id: "m1", content: "Module 1: One-Variable Equations and Inequalities" },
      { id: "m2", content: "Module 2: Two-Variable Linear Functions" },
      { id: "mO", content: "Other/not sure" },
    ],
    selectedChoiceIds: ["m1"],
  },
  {
    key: "race",
    prompt: "<p>What is your race or ethnicity? (Select all that apply)</p>",
    choices: [
      { id: "rW", content: "White" },
      { id: "rB", content: "Black or African American" },
      { id: "rH", content: "Hispanic or Latino" },
    ],
    selectedChoiceIds: ["rW"],
  },
];

const EXPECTED_CLASS = "FL-spring-2026-SHARK";

// Written by seed.js, read by run.js.
const RUN_CONTEXT_FILE = `${__dirname}/.run-context.json`;
// Written by run.js before each submit, read by stub-portal.js per request.
const SCENARIO_FILE = `${__dirname}/.scenario`;

module.exports = {
  PROJECT_ID,
  REGION,
  PORTS,
  PLATFORM_ID,
  SUBMIT_URL,
  EMULATOR_HOSTS,
  assertLoopbackEmulator,
  ORIGIN_CLASS,
  DESTINATION_CLASS,
  CONTEXT,
  REQUEST,
  ANSWERS,
  EXPECTED_CLASS,
  RUN_CONTEXT_FILE,
  SCENARIO_FILE,
};
