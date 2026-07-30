// Named scenarios that drive the stub portal's responses. Each names a
// per-endpoint behavior and the outcome report-service should reach, so run.js
// can check what actually happened against what the classifier is meant to do.
//
// Endpoint behaviors (see stub-portal.js for the exact response bodies, which
// mirror the RIGSE-352 controllers):
//   mint:     ok | expired | signature | no_shared_teacher | bad_token_type |
//             unauthorized | unauthenticated | network
//   enroll:   ok | forbidden | nonsuccess
//   lock:     ok | forbidden | notfound | server_error | network
//   offering: ok | forbidden | notfound | no_clazz | server_error
//   send:     ok | forbidden | no_teacher_email | delivery | nonsuccess
//   classes:  ok | forbidden   (under "ok", an unknown class_word still 400s)
//
// Scenarios with `driver: "run-step"` are driven by run-step.js, which calls one
// compiled step directly against the stub; the rest are whole-pipeline runs driven
// by run.js through the emulator.

const {
  DESTINATION_CLASS, ORIGIN_CLASS, STUDY_CONTROL_CLASS, TARGET_OFFERING_NAME, TREATMENT_CLASS_WORD,
  DESTINATION_SUFFIX, REQUEST,
} = require("./config");

// The open-target scenarios all drive the same step; only the stub behavior and the seeded class
// word differ.
const OPEN_TARGET_STEP = {
  driver: "run-step",
  stepModule: "open-target-offering",
  stepExport: "openTargetOffering",
  stepName: "open-target",
  // The post-test stage's pilot. Inert as behaviour (it reaches only the mint's audit description),
  // but a run-step scenario should not model a stage it is not driving.
  pilot: "fall-2026-orange",
};

const OK = { mint: "ok", enroll: "ok", lock: "ok", offering: "ok", send: "ok", classes: "ok" };

const SCENARIOS = {
  // No `context`, so its answers are seeded under the shared CONTEXT exactly as before, only under a
  // scenario-qualified document id. Every other spring scenario reads them too: the answers query
  // matches on the launch context fields rather than on the document id.
  happy: {
    describe: "Everything succeeds; the student is assigned, locked, and the class teachers are notified.",
    behavior: OK,
    seedAnswers: true,
    originClassWord: ORIGIN_CLASS.word,
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      assignedClassWord: `${ORIGIN_CLASS.word}${DESTINATION_SUFFIX.control}`,
      // Spring authors raw class ids and resolves no word, so this comes from the request rather
      // than from a classes/info fixture.
      enrolledClassId: REQUEST.control_class_id,
    },
  },

  "mint-expired": {
    describe: "The cross-class mint reports an expired forwarded token (the one terminal reason).",
    behavior: { ...OK, mint: "expired" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "reload the activity" },
  },
  "mint-no-shared-teacher": {
    describe: "The cross-class mint has no teacher shared between the origin and destination classes.",
    behavior: { ...OK, mint: "no_shared_teacher" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },
  "mint-unauthorized": {
    describe: "The OIDC client is not permitted to mint scoped tokens (403).",
    behavior: { ...OK, mint: "unauthorized" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },
  "mint-unauthenticated": {
    describe: "The mint caller resolves to no user (401, require_api_user! before require_token_minter!).",
    behavior: { ...OK, mint: "unauthenticated" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },
  "mint-network": {
    describe: "The mint connection is dropped (thrown fetch, no response).",
    behavior: { ...OK, mint: "network" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "Unable to complete your assignment" },
  },
  "mint-signature": {
    describe: "The cross-class mint rejects the forwarded token's signature (422, non-terminal reason).",
    behavior: { ...OK, mint: "signature" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },
  "mint-bad-token-type": {
    describe: "The mint rejects an unknown token_type (422, no reason).",
    behavior: { ...OK, mint: "bad_token_type" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },

  "enroll-forbidden": {
    describe: "add_to_class denies the minted teacher (Pundit 403).",
    behavior: { ...OK, enroll: "forbidden" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "tell your teacher" },
  },
  "enroll-nonsuccess": {
    describe: "add_to_class returns 200 without success:true.",
    behavior: { ...OK, enroll: "nonsuccess" },
    expect: { status: "failure", failsAt: "random-assignment", messageIncludes: "Unable to complete your assignment" },
  },

  "lock-forbidden": {
    describe: "update_student_metadata denies the origin-class teacher (403).",
    behavior: { ...OK, lock: "forbidden" },
    expect: { status: "failure", failsAt: "lock-activity", messageIncludes: "tell your teacher" },
  },
  "lock-server-error": {
    describe: "update_student_metadata fails with a 500.",
    behavior: { ...OK, lock: "server_error" },
    expect: { status: "failure", failsAt: "lock-activity", messageIncludes: "Unable to record that you finished this activity" },
  },
  "lock-network": {
    describe: "The lock connection is dropped (thrown fetch, no response) — the only thrown-fetch path outside mint.",
    behavior: { ...OK, lock: "network" },
    expect: { status: "failure", failsAt: "lock-activity", messageIncludes: "Unable to record that you finished this activity" },
  },

  "offering-forbidden": {
    describe: "The offering-read (class_id resolution) is denied (api_show? 403).",
    behavior: { ...OK, offering: "forbidden" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "tell your teacher" },
  },
  "offering-notfound": {
    describe: "The offering-read returns 404 (unresolvable class_id).",
    behavior: { ...OK, offering: "notfound" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "tell your teacher" },
  },
  "offering-no-clazz": {
    describe: "The offering-read is 200 but carries no clazz_id.",
    behavior: { ...OK, offering: "no_clazz" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "Unable to send notification email" },
  },
  "offering-server-error": {
    describe: "The offering-read fails with a 500.",
    behavior: { ...OK, offering: "server_error" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "Unable to send notification email" },
  },

  "send-forbidden": {
    describe: "send_class_teachers denies the acting teacher (class_teacher? 403).",
    behavior: { ...OK, send: "forbidden" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "tell your teacher" },
  },
  "send-delivery": {
    describe: "send_class_teachers fails delivery (502).",
    behavior: { ...OK, send: "delivery" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "Unable to send notification email" },
  },
  "send-no-teacher-email": {
    describe: "send_class_teachers reports no teacher has an email configured (422, no reason).",
    behavior: { ...OK, send: "no_teacher_email" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "tell your teacher" },
  },
  "send-nonsuccess": {
    describe: "send_class_teachers returns 200 without success:true.",
    behavior: { ...OK, send: "nonsuccess" },
    expect: { status: "failure", failsAt: "send-email", messageIncludes: "Unable to send notification email" },
  },

  "enroll-happy": {
    describe: `The enroll step resolves the class word "${DESTINATION_CLASS.word}" to its own class and enrolls the student there (run twice, so a re-invocation with the same token cache is covered).`,
    driver: "run-step",
    behavior: OK,
    targetClassWord: DESTINATION_CLASS.word,
    expect: { status: "success", summaryIncludes: `Enrolled in ${DESTINATION_CLASS.name}` },
  },
  "enroll-unknown-word": {
    describe: "The destination class word matches no class (classes#info 400).",
    driver: "run-step",
    behavior: OK,
    targetClassWord: "FT-fall-2026-does-not-exist",
    expect: { status: "failure", messageIncludes: "tell your teacher" },
  },
  "open-target-happy": {
    describe: `The open step classifies "${STUDY_CONTROL_CLASS.word}" as control, resolves "${TARGET_OFFERING_NAME}" among the class's two offerings, and unlocks and reveals it (run twice, covering re-entry with a populated token cache and accumulated stepResults).`,
    ...OPEN_TARGET_STEP,
    behavior: OK,
    seedOriginClassWord: STUDY_CONTROL_CLASS.word,
    expect: { status: "success", summaryIncludes: `Opened ${TARGET_OFFERING_NAME}` },
  },
  "open-target-treatment": {
    // Needs no class fixture: the arm check short-circuits before the mint and the class read, so
    // nothing looks this word up. Watch terminal 2 for the absent PUT.
    describe: "A treatment student's post-test: the step does nothing and says so, with no portal call at all.",
    ...OPEN_TARGET_STEP,
    behavior: OK,
    seedOriginClassWord: TREATMENT_CLASS_WORD,
    expect: { status: "success", summaryIncludes: "No activity to open" },
  },
  "open-target-lookup-forbidden": {
    describe: "classes#info denies the origin teacher token (403) while resolving the target's class.",
    ...OPEN_TARGET_STEP,
    behavior: { ...OK, classes: "forbidden" },
    seedOriginClassWord: STUDY_CONTROL_CLASS.word,
    expect: { status: "failure", messageIncludes: "tell your teacher" },
  },
  "open-target-write-error": {
    describe: "The target resolves but update_student_metadata fails with a 500.",
    ...OPEN_TARGET_STEP,
    behavior: { ...OK, lock: "server_error" },
    seedOriginClassWord: STUDY_CONTROL_CLASS.word,
    expect: { status: "failure", messageIncludes: "Your work has been saved" },
  },

  "enroll-lookup-forbidden": {
    describe: "classes#info denies the origin teacher token (403).",
    driver: "run-step",
    behavior: { ...OK, classes: "forbidden" },
    targetClassWord: DESTINATION_CLASS.word,
    expect: { status: "failure", messageIncludes: "tell your teacher" },
  },
};

module.exports = { SCENARIOS, OK };
