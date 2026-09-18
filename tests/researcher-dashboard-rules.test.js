const firebase = require("@firebase/rules-unit-testing");

const PROJECT = "report-service-dev";
const PORTAL = "learn_portal_staging_concord_org";
const PLATFORM = "https://learn.portal.staging.concord.org";
const OTHER_PLATFORM = "https://learn.concord.org";
const CLASS = "7be899cf665898097ed1ec57f34b700e156bd4544ffd693f";
const OTHER_CLASS = "64727df0c5f4bdf6e8d36b217499f6e0e6881a1cff852558";
const RESEARCHER = 200;
const OTHER_RESEARCHER = 136;
const UNWRITTEN = 999;

// The six token shapes the dashboard's rules have to tell apart. The two runner shapes
// differ only by class_hash, and that difference is load-bearing: the session token the VM
// holds from launch cannot write a class's results, so a runner that used it for a
// class-scoped write would be denied here rather than silently writing under the wrong
// scope.
const sessionRunner = {
  uid: "uid-runner", platform_id: PLATFORM, platform_user_id: RESEARCHER,
  user_type: "researcher", researcher_dashboard_runner: true
};
const classRunner = { ...sessionRunner, class_hash: CLASS };
const otherClassRunner = { ...sessionRunner, class_hash: OTHER_CLASS };
const plainResearcher = {
  uid: "uid-researcher", platform_id: PLATFORM, platform_user_id: RESEARCHER,
  user_type: "researcher", class_hash: CLASS
};
const otherResearcher = { ...plainResearcher, uid: "uid-other", platform_user_id: OTHER_RESEARCHER };
const otherPortalRunner = { ...classRunner, platform_id: OTHER_PLATFORM };
// A second researcher of the SAME class. Both hold class tokens for the same
// class_hash, so this is the token that can reach another researcher's analysis if
// the rules pin requested_by only on create.
const otherResearcherRunner = {
  ...classRunner, uid: "uid-other-runner", platform_user_id: OTHER_RESEARCHER
};
const unwrittenResearcher = { ...plainResearcher, uid: "uid-unwritten", platform_user_id: UNWRITTEN };

// One app per token shape, built once. The client SDK does not survive an app per call
// (FIRESTORE INTERNAL ASSERTION FAILED), and clearing emulator data between tests while
// clients are connected wedges it the same way, so each test uses its own document ids
// instead of a clean database.
const tokens = {
  sessionRunner, classRunner, otherClassRunner, plainResearcher, otherResearcher,
  otherPortalRunner, otherResearcherRunner, unwrittenResearcher, anonymous: null
};
const dbs = {};
let admin;

beforeAll(() => {
  Object.keys(tokens).forEach(name => {
    dbs[name] = firebase.initializeTestApp({ projectId: PROJECT, auth: tokens[name] }).firestore();
  });
  admin = firebase.initializeAdminApp({ projectId: PROJECT }).firestore();
});

function db(name) {
  return dbs[name];
}
function adminDb() {
  return admin;
}

const researcherPath = (id) => `researcher_dashboard/${PORTAL}/researchers/${id}`;
const classPath = (hash) => `researcher_dashboard/${PORTAL}/classes/${hash}`;
const resultPath = (hash, pkg) => `${classPath(hash)}/results/${pkg}`;

const statusDoc = { platform_id: PLATFORM, state: "ready", microvm_id: "mvm-1", updated_at: 1 };
const classDoc = { platform_id: PLATFORM, data: { clue_documents: 22 }, last_pulled_by: RESEARCHER };
const resultDoc = {
  platform_id: PLATFORM, status: "running", stage: "pull", requested_by: String(RESEARCHER),
  package: { name: "counts", version: "1.0.0", checksum: "sha256:abc" }
};

afterAll(async () => {
  await Promise.all(firebase.apps().map(a => a.delete()));
});

describe("researcher status document", () => {
  it("is readable by the researcher it belongs to", async () => {
    await adminDb().doc(researcherPath(RESEARCHER)).set(statusDoc);
    await firebase.assertSucceeds(db('plainResearcher').doc(researcherPath(RESEARCHER)).get());
  });

  it("reads as permitted before it exists, so the page can attach its listener", async () => {
    // The point is the ABSENT document, so this needs an id no other test writes and a
    // token whose platform_user_id matches it; otherwise an earlier test's write satisfies
    // it through the existing-document branch and the rule under test never runs.
    await firebase.assertSucceeds(db('unwrittenResearcher').doc(researcherPath(UNWRITTEN)).get());
  });

  it("is not readable by another researcher", async () => {
    await adminDb().doc(researcherPath(RESEARCHER)).set(statusDoc);
    await firebase.assertFails(db('otherResearcher').doc(researcherPath(RESEARCHER)).get());
  });

  it("is not readable unauthenticated", async () => {
    await adminDb().doc(researcherPath(RESEARCHER)).set(statusDoc);
    await firebase.assertFails(db('anonymous').doc(researcherPath(RESEARCHER)).get());
  });

  it("is written by the session runner token, which carries no class", async () => {
    await firebase.assertSucceeds(db('sessionRunner').doc(researcherPath(RESEARCHER)).set(statusDoc));
  });

  it("is not written by a plain researcher token, which lacks the runner claim", async () => {
    await firebase.assertFails(db('plainResearcher').doc(researcherPath(RESEARCHER)).set(statusDoc));
  });

  it("is not written by a runner token for a different researcher", async () => {
    await firebase.assertFails(db('sessionRunner').doc(researcherPath(OTHER_RESEARCHER)).set(statusDoc));
  });

  it("cannot be deleted by the runner", async () => {
    await adminDb().doc(researcherPath(RESEARCHER)).set(statusDoc);
    await firebase.assertFails(db('sessionRunner').doc(researcherPath(RESEARCHER)).delete());
  });

  it("is not written with another portal's platform_id", async () => {
    await firebase.assertFails(
      db('otherPortalRunner').doc(researcherPath(RESEARCHER)).set({ ...statusDoc, platform_id: OTHER_PLATFORM }));
  });
});

describe("class document", () => {
  it("is readable by a researcher of that class", async () => {
    await adminDb().doc(classPath(CLASS)).set(classDoc);
    await firebase.assertSucceeds(db('plainResearcher').doc(classPath(CLASS)).get());
  });

  it("is not readable by a researcher of another class", async () => {
    await adminDb().doc(classPath(CLASS)).set(classDoc);
    await firebase.assertFails(db('otherClassRunner').doc(classPath(CLASS)).get());
  });

  it("is written by the class runner token", async () => {
    await firebase.assertSucceeds(db('classRunner').doc(classPath(CLASS)).set(classDoc));
  });

  // The runner signs in once at /run with the session token; this is the rule that makes
  // using it for a class-scoped write fail rather than silently write out of scope.
  it("is NOT written by the session runner token, which carries no class_hash", async () => {
    await firebase.assertFails(db('sessionRunner').doc(classPath(CLASS)).set(classDoc));
  });

  it("is not written by a plain researcher token", async () => {
    await firebase.assertFails(db('plainResearcher').doc(classPath(CLASS)).set(classDoc));
  });
});

describe("result document", () => {
  it("is written by the class runner token", async () => {
    await firebase.assertSucceeds(db('classRunner').doc(resultPath(CLASS, "counts")).set(resultDoc));
  });

  it("cannot be written by the session runner token, which carries no class_hash", async () => {
    await firebase.assertFails(db('sessionRunner').doc(resultPath(CLASS, "s-counts")).set(resultDoc));
  });

  it("cannot be written by a plain researcher token", async () => {
    await firebase.assertFails(db('plainResearcher').doc(resultPath(CLASS, "p-counts")).set(resultDoc));
  });

  // One document per class and package, shared by every researcher of the class, so a
  // second researcher re-running the same package overwrites it on purpose.
  it("is overwritten by another researcher of the same class, which is the intent", async () => {
    await adminDb().doc(resultPath(CLASS, "shared")).set(resultDoc);
    await firebase.assertSucceeds(
      db('otherResearcherRunner').doc(resultPath(CLASS, "shared"))
        .update({ status: "done", requested_by: String(OTHER_RESEARCHER) }));
  });

  it("is refused when the document carries no platform_id", async () => {
    // The rules check platform_id on every write. A fixture that always seeds it
    // cannot catch a runner that never writes it, which is how this was missed.
    const { platform_id, ...withoutPlatform } = resultDoc;
    await firebase.assertFails(
      db('classRunner').doc(resultPath(CLASS, "noplat")).set(withoutPlatform));
  });

  it("cannot be deleted, even by the runner that wrote it", async () => {
    await adminDb().doc(resultPath(CLASS, "undeletable")).set(resultDoc);
    await firebase.assertFails(db('classRunner').doc(resultPath(CLASS, "undeletable")).delete());
  });

  it("is readable by any researcher of the class, since results are shared", async () => {
    await adminDb().doc(resultPath(CLASS, "readable")).set(resultDoc);
    await firebase.assertSucceeds(db('plainResearcher').doc(resultPath(CLASS, "readable")).get());
  });

  it("is not readable by a researcher of another class", async () => {
    await adminDb().doc(resultPath(CLASS, "other-class")).set(resultDoc);
    await firebase.assertFails(db('otherClassRunner').doc(resultPath(CLASS, "other-class")).get());
  });

  it("is not readable unauthenticated", async () => {
    await adminDb().doc(resultPath(CLASS, "anon")).set(resultDoc);
    await firebase.assertFails(db('anonymous').doc(resultPath(CLASS, "anon")).get());
  });

  it("lists a class's results for a researcher of that class", async () => {
    await adminDb().doc(resultPath(CLASS, "one")).set(resultDoc);
    await adminDb().doc(resultPath(CLASS, "two")).set(resultDoc);
    await firebase.assertSucceeds(db('plainResearcher').collection(`${classPath(CLASS)}/results`).get());
  });
});

// The dashboard would like to listen for AP answer changes class-wide. The existing rules
// grant a researcher of the class each answer document individually; whether a class-wide
// QUERY passes is a different question, and these are the tests that answer it rather
// than guess. The answer is no, for either class, so a class-wide answers listener is not
// available to the dashboard and a live AP count has to come from somewhere else.
describe("class-wide answers query for the dashboard listener", () => {
  const answersPath = "sources/activity-player.concord.org/answers";
  const answer = (contextId) => ({
    platform_id: PLATFORM, context_id: contextId, platform_user_id: 999,
    question_id: "q1", answer: "an answer"
  });

  // Refused even for the researcher's own class: studentWorkRead is a chain of
  // predicates over resource.data, which a query cannot satisfy document by document, so
  // the request is denied rather than filtered. Individual gets are unaffected.
  it("cannot query even its own class's answers", async () => {
    await adminDb().doc(`${answersPath}/ans1`).set(answer(CLASS));
    const q = db('plainResearcher').collection(answersPath).where("context_id", "==", CLASS);
    await firebase.assertFails(q.get());
  });

  it("the same token cannot query another class's answers", async () => {
    await adminDb().doc(`${answersPath}/ans2`).set(answer(OTHER_CLASS));
    const q = db('plainResearcher').collection(answersPath).where("context_id", "==", OTHER_CLASS);
    await firebase.assertFails(q.get());
  });
});
