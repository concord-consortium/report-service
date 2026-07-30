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

// The fall control subclass. Its word must carry the "-shark" arm suffix, or open-target-offering
// short-circuits on the arm check before the mint, the class read and the name match, and the
// scenario reports a passing tell-your-teacher while the matching logic never runs. Neither class
// word above carries either suffix.
const STUDY_CONTROL_CLASS = { id: 30002, word: "ft-2026-bingler-shark", name: "FT-2026-Bingler-Shark" };

// ⚠️ Must equal TARGET_OFFERING_NAME exported by open-target-offering.ts, or the by-name match
// resolves nothing and every open-target scenario fails. A literal rather than an import of the
// compiled constant, because stub-portal.js requires only http/fs/./config/./scenarios today, and
// importing from lib/ would give it a dependency on a build in the process the README says to start
// first, with no equivalent of run-step.js's existsSync guard. A unit test asserts the two match.
const TARGET_OFFERING_NAME = "Blue Sequence for AI in Math (FLVS 26-27)";

// classes/info is read by exactly TWO steps: enroll-specified-class looks up the DESTINATION word,
// and open-target-offering looks up the ORIGIN word on the post-test stage. The registration words
// (ft-2026-bingler, fl-2026-section1) are looked up by neither, and are deliberately not here, so
// the fixture set does not imply the origin is resolved through this endpoint. They ARE served by
// offerings#show, from the separate identity map below.
const FALL_FT_TREATMENT_CLASS = { id: 30011, word: "ft-2026-bingler-gator", name: "FT-2026-Bingler-Gator" };
const FALL_FLEX_CONTROL_CLASS = { id: 30012, word: "fl-2026-section1-shark", name: "FL-2026-Section1-Shark" };
// For the arm the sticky assignment can flip to. An edited ANSWERS or an un-reset pooled document
// lands the flex scenario in treatment, whose destination would otherwise have no fixture; that
// surfaces as a classes#info 400 and the generic tell-your-teacher message, with nothing naming the
// missing fixture. Full-time's flipped destination is ft-2026-bingler-shark, which already exists as
// STUDY_CONTROL_CLASS, so only the flex arm has this hole.
const FALL_FLEX_TREATMENT_CLASS = { id: 30013, word: "fl-2026-section1-gator", name: "FL-2026-Section1-Gator" };

// ⚠️ NOT classes/info fixtures, and they must not be added to CLASSES_BY_WORD. A fall pre-test
// launches from a registration class, so resolveOriginClass reads one through offerings#show and
// every downstream decision hangs off the class word it publishes; but no step ever looks these
// words up by name, which is the property the comment above records. They are therefore a separate
// identity-only pair, consumed by stub-portal.js's ORIGIN_IDENTITY_BY_WORD and by nothing else.
//
// Without them the pre-test scenarios do not fail loudly, they fail WRONGLY: offerings#show falls
// back to the spring origin class, resolveOriginClass publishes fl-spring-2026-origin,
// classifyFallProgram returns undefined, and the run reports "unclassifiable origin class word",
// which reads as a pipeline fault.
const FALL_FT_REGISTRATION_CLASS = { id: 30021, word: "ft-2026-bingler", name: "FT-2026-Bingler" };
const FALL_FLEX_REGISTRATION_CLASS = { id: 30022, word: "fl-2026-section1", name: "FL-2026-Section1" };

// The treatment subclass word, which is FALL_FT_TREATMENT_CLASS's. open-target-treatment still needs
// no fixture for it, since that scenario's arm check short-circuits before any portal call, but the
// full-time pre-test scenario enrols into it, so enroll-specified-class resolves it by name.
const TREATMENT_CLASS_WORD = FALL_FT_TREATMENT_CLASS.word;

// ⚠️ Duplicates of fall-programs.ts's DESTINATION_SUFFIX and FLEX_PROGRAM. Literals rather than
// imports for the same reason TARGET_OFFERING_NAME is one: run.js requires only fs, crypto, ./config,
// ./scenarios and firebase-admin, and giving it a dependency on a build would oblige it to carry
// run-step.js's existsSync guard. Both are pinned by a unit test in open-target-offering.test.ts.
//
// ⚠️ FLEX_PROGRAM is hashed into the pooled assignment document id, so a rename is a data migration
// rather than a refactor; the pin is what makes a rename fail loudly here too.
const DESTINATION_SUFFIX = { treatment: "-gator", control: "-shark" };
const FLEX_PROGRAM = "fall-2026-flex";

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

// Per-scenario launch contexts for the fall stages. ADDITIONS, not edits: CONTEXT keeps its current
// values, because stub-portal.js gives the study control class an Orange offering whose id IS
// CONTEXT.resource_link_id, precisely so the by-name match has to discriminate AGAINST the offering
// the student launched from rather than picking the only one available. That is the property
// open-target-happy exercises.
//
// ⚠️ The isolation this buys is FULL-TIME's only. perClassScope hashes resource_link_id and
// context_id, so without its own pair a fall full-time run lands in the SAME assignment document as
// the spring `happy` scenario, where the per-student de-duplication hands it spring's arm and the
// scenario silently stops testing what it claims to. pooledProgramScope takes program, interactiveId
// and platform_id and nothing else, so the flex scenario's own pair changes its document id not at
// all; flex is separated from spring by the pooled namespace prefix and by FLEX_PROGRAM being in the
// hash. The consequence to hold on to is that the flex assignment document is per PROGRAM, not per
// scenario.
const FALL_CONTEXTS = {
  "fall-green-fulltime": { resource_link_id: "im-done-fall-green-ft", context_id: "im-done-fall-green-ft-ctx" },
  "fall-green-flex": { resource_link_id: "im-done-fall-green-flex", context_id: "im-done-fall-green-flex-ctx" },
  "fall-orange-control": { resource_link_id: "im-done-fall-orange", context_id: "im-done-fall-orange-ctx" },
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

// Written by seed.js, read by run.js.
const RUN_CONTEXT_FILE = `${__dirname}/.run-context.json`;
// Written by run.js before each submit, read by stub-portal.js per request.
const SCENARIO_FILE = `${__dirname}/.scenario`;
// Written by stub-portal.js on every add_to_class, read by run.js after a run. The stub and the
// driver are separate processes, so a file is the channel available, as .scenario already is.
const LAST_ENROLL_FILE = `${__dirname}/.last-enroll.json`;

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
  STUDY_CONTROL_CLASS,
  TARGET_OFFERING_NAME,
  TREATMENT_CLASS_WORD,
  FALL_FT_TREATMENT_CLASS,
  FALL_FLEX_CONTROL_CLASS,
  FALL_FLEX_TREATMENT_CLASS,
  FALL_FT_REGISTRATION_CLASS,
  FALL_FLEX_REGISTRATION_CLASS,
  DESTINATION_SUFFIX,
  FLEX_PROGRAM,
  CONTEXT,
  FALL_CONTEXTS,
  REQUEST,
  ANSWERS,
  RUN_CONTEXT_FILE,
  SCENARIO_FILE,
  LAST_ENROLL_FILE,
};
