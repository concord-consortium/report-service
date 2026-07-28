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

const OK = { mint: "ok", enroll: "ok", lock: "ok", offering: "ok", send: "ok" };

const SCENARIOS = {
  happy: {
    describe: "Everything succeeds; the student is assigned, locked, and the class teachers are notified.",
    behavior: OK,
    expect: { status: "success", messageIncludes: "teacher has been notified" },
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
    expect: { status: "failure", failsAt: "lock-activity", messageIncludes: "Unable to lock your pre-test" },
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
};

module.exports = { SCENARIOS, OK };
