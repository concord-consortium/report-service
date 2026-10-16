// Researcher Dashboard activity rules against the Firestore emulator, run as
// researcher-dashboard-rules.test.js describes.
//
// researcher_dashboard/{portal}/activity/{class_hash}/users/{platform_user_id} is written only by the
// researcherDashboardActivity function with the Admin SDK, and read and listed by the class's researchers.
const firebase = require("@firebase/rules-unit-testing");

const PROJECT = "report-service-dev";
const PLATFORM = "https://learn.portal.staging.concord.org/";
const PORTAL = "learn_portal_staging_concord_org";
const ROOT = `researcher_dashboard/${PORTAL}`;
const CLASS_A = "a".repeat(48);
const CLASS_B = "b".repeat(48);
// No document is ever written under this class
const CLASS_EMPTY = "e".repeat(48);

// A session signed in now, so rdIsRunner() holds for the runner shape
const researcher = { uid: "uid-42", platform_id: PLATFORM, platform_user_id: 42, user_type: "researcher", auth_time: Math.floor(Date.now() / 1000) };
const shapes = {
  browser: { ...researcher, class_hash: CLASS_A },
  classRunner: { ...researcher, researcher_dashboard_runner: true, class_hash: CLASS_A },
  emptyClass: { ...researcher, class_hash: CLASS_EMPTY },
  otherClass: { ...researcher, class_hash: CLASS_B },
  otherPortal: { ...researcher, platform_id: "https://learn.concord.org/", class_hash: CLASS_A },
  learner: { ...researcher, user_type: "learner", class_hash: CLASS_A },
  teacher: { ...researcher, user_type: "teacher", class_hash: CLASS_A },
  anon: null,
};

// One app per token shape, built once: the v8 client does not survive an app per call.
const apps = {};
const db = (shape) => apps[shape].firestore();
let admin;
const adminDb = () => admin.firestore();

beforeAll(() => {
  for (const [shape, auth] of Object.entries(shapes)) {
    apps[shape] = firebase.initializeTestApp({ projectId: PROJECT, auth });
  }
  admin = firebase.initializeAdminApp({ projectId: PROJECT });
});
afterAll(() => Promise.all(firebase.apps().map((app) => app.delete())));

const users = (classHash = CLASS_A) => `${ROOT}/activity/${classHash}/users`;
// Distinct learner ids per test, since the harness does not clear the emulator between tests.
let counter = 1000;
const nextLearner = () => String(counter++);
const activity = () => ({ lastActivityAt: new Date(), writeCount: 1, changed: { 701: new Date() } });

describe("activity/{class_hash}/users/{platform_user_id}", () => {
  it("is read and listed by the class's researcher", async () => {
    const learner = nextLearner();
    await adminDb().doc(`${users()}/${learner}`).set(activity());

    await firebase.assertSucceeds(db("browser").doc(`${users()}/${learner}`).get());
    const list = await firebase.assertSucceeds(db("browser").collection(users()).get());
    expect(list.docs.map((d) => d.id)).toContain(learner);
  });

  it("gives a listener on a class with no activity an empty snapshot", async () => {
    const snapshot = await new Promise((resolve, reject) => {
      const stop = db("emptyClass").collection(users(CLASS_EMPTY)).onSnapshot((s) => { stop(); resolve(s); }, reject);
    });
    expect(snapshot.empty).toBe(true);
  });

  it.each(["otherClass", "otherPortal", "learner", "teacher", "anon"])("is not read or listed by %s", async (shape) => {
    const learner = nextLearner();
    await adminDb().doc(`${users()}/${learner}`).set(activity());

    await firebase.assertFails(db(shape).doc(`${users()}/${learner}`).get());
    await firebase.assertFails(db(shape).collection(users()).get());
  });

  it.each(["browser", "classRunner"])("is not created, updated or deleted by %s", async (shape) => {
    const learner = nextLearner();
    await adminDb().doc(`${users()}/${learner}`).set(activity());

    await firebase.assertFails(db(shape).doc(`${users()}/${nextLearner()}`).set(activity()));
    await firebase.assertFails(db(shape).doc(`${users()}/${learner}`).update({ writeCount: 2 }));
    await firebase.assertFails(db(shape).doc(`${users()}/${learner}`).delete());
  });

  it("does not open the class's activity document itself", async () => {
    await adminDb().doc(`${ROOT}/activity/${CLASS_A}`).set({ any: true });
    await firebase.assertFails(db("browser").doc(`${ROOT}/activity/${CLASS_A}`).get());
  });
});
