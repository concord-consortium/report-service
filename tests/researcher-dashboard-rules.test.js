// Researcher Dashboard security rules against the Firestore emulator.
//
// Run from tests/ with:  npx firebase -c ../firebase.json emulators:exec --only firestore "npm test"
// (the same @firebase/rules-unit-testing v1 harness as the other suites: `auth` is the token).
//
// The browser reads; only a token carrying researcher_dashboard_runner writes, and only its own
// researcher's documents on its own portal. vms/ and work/ are the function's alone. Admin app
// writes bypass rules, as the function's Admin SDK writes do.
const firebase = require("@firebase/rules-unit-testing");

const PROJECT = "report-service-dev";
const PLATFORM = "https://learn.portal.staging.concord.org/";
const PORTAL = "learn_portal_staging_concord_org";
const ROOT = `researcher_dashboard/${PORTAL}`;
const CLASS_A = "a".repeat(48);
const CLASS_B = "b".repeat(48);

const researcher = { uid: "uid-42", platform_id: PLATFORM, platform_user_id: 42, user_type: "researcher" };
const shapes = {
  browser: { ...researcher, class_hash: CLASS_A },
  sessionRunner: { ...researcher, researcher_dashboard_runner: true },
  classRunner: { ...researcher, researcher_dashboard_runner: true, class_hash: CLASS_A },
  otherClass: { ...researcher, class_hash: CLASS_B },
  otherResearcher: { ...researcher, uid: "uid-43", platform_user_id: 43, class_hash: CLASS_A },
  otherPortalRunner: { ...researcher, platform_id: "https://learn.concord.org/", researcher_dashboard_runner: true, class_hash: CLASS_A },
  newResearcher: { ...researcher, uid: "uid-44", platform_user_id: 44 },
  teacher: { ...researcher, user_type: "teacher", class_hash: CLASS_A },
  otherResearcherRunner: { ...researcher, uid: "uid-43", platform_user_id: 43, researcher_dashboard_runner: true, class_hash: CLASS_A },
  anon: null,
};

// One app per token shape, built once: the v8 client does not survive an app per call.
const apps = {};
const db = (shape) => apps[shape].firestore();
let admin;
const adminDb = () => admin.firestore();
const serverTime = () => firebase.firestore.FieldValue.serverTimestamp();

// Distinct document ids per test, since the harness does not clear the emulator between tests.
let counter = 0;
const nextKey = () => `users__1__pkg-${Date.now()}-${counter++}`;
const resultPath = (key, classHash = CLASS_A, platformUserId = 42) =>
  `${ROOT}/classes/${classHash}/researchers/${platformUserId}/results/${key}`;
// An undefined in `over` leaves that field out.
const running = (over = {}) => Object.fromEntries(Object.entries({
  status: "running", platform_id: PLATFORM, expected_duration_seconds: 600, microvm_id: "vm-1", heartbeat_seconds: 60,
  updated_at: serverTime(), started_at: serverTime(), ...over,
}).filter(([, value]) => value !== undefined));

beforeAll(() => {
  for (const [shape, auth] of Object.entries(shapes)) {
    apps[shape] = firebase.initializeTestApp({ projectId: PROJECT, auth });
  }
  admin = firebase.initializeAdminApp({ projectId: PROJECT });
});
afterAll(() => Promise.all(firebase.apps().map((app) => app.delete())));

describe("work/ and vms/", () => {
  it.each(["work", "vms"])("refuse every client token %s's get, set and list", async (collection) => {
    for (const shape of ["browser", "sessionRunner", "classRunner"]) {
      const doc = db(shape).doc(`${ROOT}/${collection}/42`);
      await firebase.assertFails(doc.get());
      await firebase.assertFails(doc.set({ platform_id: PLATFORM, updated_at: serverTime() }));
      await firebase.assertFails(db(shape).collection(`${ROOT}/${collection}`).get());
    }
  });
});

describe("classes/{class_hash}", () => {
  it("is read by its researcher and by no other class's, and written or deleted by no client", async () => {
    const path = `${ROOT}/classes/${CLASS_A}`;
    await adminDb().doc(path).set({ platform_id: PLATFORM, data: { answers: [] } });

    await firebase.assertSucceeds(db("browser").doc(path).get());
    await firebase.assertFails(db("otherClass").doc(path).get());
    await firebase.assertFails(db("classRunner").doc(path).set({ platform_id: PLATFORM }));
    await firebase.assertFails(db("classRunner").doc(path).update({ platform_id: PLATFORM }));
    await firebase.assertFails(db("classRunner").doc(path).delete());
  });
});

describe("runners/{platform_user_id}", () => {
  const path = `${ROOT}/runners/42`;

  it("is written by the session runner with the server's time, and refused a client clock", async () => {
    await firebase.assertSucceeds(db("sessionRunner").doc(path).set({ platform_id: PLATFORM, state: "ready", updated_at: serverTime() }));
    await firebase.assertFails(db("sessionRunner").doc(path).set({ platform_id: PLATFORM, state: "ready", updated_at: new Date() }));
    await firebase.assertFails(db("sessionRunner").doc(path).update({ state: "running" }));
    await firebase.assertSucceeds(db("sessionRunner").doc(path).update({ state: "running", updated_at: serverTime() }));
  });

  it("is read but not written by the browser, and not read by another researcher", async () => {
    await adminDb().doc(path).set({ platform_id: PLATFORM, state: "ready" });

    await firebase.assertSucceeds(db("browser").doc(path).get());
    await firebase.assertFails(db("browser").doc(path).set({ platform_id: PLATFORM, updated_at: serverTime() }));
    await firebase.assertFails(db("otherResearcher").doc(path).get());
  });

  it("is not written by another portal's runner, and deleted by no one", async () => {
    await firebase.assertFails(db("otherPortalRunner").doc(path).set({ platform_id: "https://learn.concord.org/", updated_at: serverTime() }));
    await firebase.assertFails(db("sessionRunner").doc(path).delete());
    await firebase.assertFails(db("browser").doc(path).delete());
  });

  it("is readable by its researcher before it exists", async () => {
    await firebase.assertSucceeds(db("newResearcher").doc(`${ROOT}/runners/44`).get());
  });
});

describe("results", () => {
  it("are written running by the class runner with the claimed run's fields", async () => {
    await firebase.assertSucceeds(db("classRunner").doc(resultPath(nextKey())).set(running()));
  });

  it.each([
    ["a duration past the VM's life", { expected_duration_seconds: 28801 }],
    ["a duration that is not an integer", { expected_duration_seconds: 600.5 }],
    ["a duration of 0", { expected_duration_seconds: 0 }],
    ["a null microvm_id", { microvm_id: null }],
    ["no heartbeat_seconds", { heartbeat_seconds: undefined }],
    ["a heartbeat_seconds of 29", { heartbeat_seconds: 29 }],
    ["a heartbeat_seconds of 121", { heartbeat_seconds: 121 }],
    ["a heartbeat_seconds that is not an integer", { heartbeat_seconds: 60.5 }],
    ["a string updated_at", { updated_at: new Date().toISOString() }],
    ["a client clock as started_at", { started_at: new Date() }],
  ])("refuse a running result with %s", async (_, over) => {
    await firebase.assertFails(db("classRunner").doc(resultPath(nextKey())).set(running(over)));
  });

  it("move to done in an update that keeps the claimed started_at", async () => {
    const doc = db("classRunner").doc(resultPath(nextKey()));
    await firebase.assertSucceeds(doc.set(running()));
    await firebase.assertSucceeds(doc.update({ status: "done", summary: "3 classes", updated_at: serverTime(), finished_at: serverTime() }));
  });

  it("take a heartbeat: a merge of only platform_id and a server-time updated_at", async () => {
    const doc = db("classRunner").doc(resultPath(nextKey()));
    await firebase.assertSucceeds(doc.set(running()));
    await firebase.assertSucceeds(doc.set({ platform_id: PLATFORM, updated_at: serverTime() }, { merge: true }));
  });

  it("refuse an update that changes started_at to a client clock", async () => {
    const doc = db("classRunner").doc(resultPath(nextKey()));
    await firebase.assertSucceeds(doc.set(running()));
    await firebase.assertFails(doc.update({ started_at: new Date(), updated_at: serverTime() }));
  });

  it("are not written by a token without the class, by the browser, or into another researcher's", async () => {
    const key = nextKey();
    await firebase.assertFails(db("sessionRunner").doc(resultPath(key)).set(running()));
    await firebase.assertFails(db("browser").doc(resultPath(key)).set(running()));
    await firebase.assertFails(db("classRunner").doc(resultPath(key, CLASS_A, 43)).set(running()));
  });

  it("are deleted by no one", async () => {
    const path = resultPath(nextKey());
    await adminDb().doc(path).set({ status: "done", platform_id: PLATFORM });
    await firebase.assertFails(db("classRunner").doc(path).delete());
    await firebase.assertFails(db("browser").doc(path).delete());
  });

  it("are got and listed by their researcher, and by no other class's, other researcher or anonymous caller", async () => {
    const path = resultPath(nextKey());
    await adminDb().doc(path).set({ status: "done", platform_id: PLATFORM });
    const results = `${ROOT}/classes/${CLASS_A}/researchers/42/results`;

    await firebase.assertSucceeds(db("browser").doc(path).get());
    await firebase.assertSucceeds(db("browser").collection(results).get());
    for (const shape of ["otherClass", "otherResearcher", "anon"]) {
      await firebase.assertFails(db(shape).doc(path).get());
      await firebase.assertFails(db(shape).collection(results).get());
    }
  });

  it("can be listened to before the result exists", async () => {
    const snapshot = await new Promise((resolve, reject) => {
      const stop = db("browser").doc(resultPath(nextKey())).onSnapshot(
        (snap) => { stop(); resolve(snap); },
        (error) => { stop(); reject(error); }
      );
    });
    expect(snapshot.exists).toBe(false);
  });

  it("of another platform are not readable", async () => {
    const path = resultPath(nextKey());
    await adminDb().doc(path).set({ status: "done", platform_id: "https://other.example/" });
    await firebase.assertFails(db("browser").doc(path).get());
  });
});

describe("the scope document", () => {
  const path = `${ROOT}/classes/${CLASS_A}/researchers/42`;

  it("is not read by another class's or another researcher's token, nor written by another researcher's runner", async () => {
    await adminDb().doc(path).set({ platform_id: PLATFORM, scope: { kind: "class" } });
    await firebase.assertFails(db("otherClass").doc(path).get());
    await firebase.assertFails(db("otherResearcher").doc(path).get());
    await firebase.assertFails(db("otherResearcherRunner").doc(path).set({ platform_id: PLATFORM, scope: { kind: "class" } }));
  });

  it("is not written with another platform's platform_id", async () => {
    await firebase.assertFails(db("classRunner").doc(path).set({ platform_id: "https://other.example/", scope: { kind: "class" } }));
  });

  it("is written by the class runner without updated_at, and read but not written by the browser", async () => {
    await firebase.assertSucceeds(db("classRunner").doc(path).set({ platform_id: PLATFORM, scope: { kind: "class" } }));
    await firebase.assertSucceeds(db("browser").doc(path).get());
    await firebase.assertFails(db("browser").doc(path).set({ platform_id: PLATFORM }));
  });
});

describe("a token that is not a researcher's", () => {
  it("is refused the runner document and a result, for the same user, class and portal", async () => {
    const runner = `${ROOT}/runners/42`;
    const result = resultPath(nextKey());
    await adminDb().doc(runner).set({ platform_id: PLATFORM, state: "ready" });
    await adminDb().doc(result).set({ status: "done", platform_id: PLATFORM });
    await firebase.assertSucceeds(db("browser").doc(result).get());
    await firebase.assertFails(db("teacher").doc(runner).get());
    await firebase.assertFails(db("teacher").doc(result).get());
  });
});

describe("a runner write", () => {
  it("is refused another researcher's runner document", async () => {
    await firebase.assertFails(db("otherResearcherRunner").doc(`${ROOT}/runners/42`).set({ platform_id: PLATFORM, updated_at: serverTime() }));
    await firebase.assertSucceeds(db("sessionRunner").doc(`${ROOT}/runners/42`).set({ platform_id: PLATFORM, updated_at: serverTime() }));
  });

  it("is refused a result carrying another platform's platform_id", async () => {
    await firebase.assertFails(db("classRunner").doc(resultPath(nextKey())).set(running({ platform_id: "https://other.example/" })));
  });
});

describe("a document of another platform", () => {
  it.each([
    ["the runner document", `${ROOT}/runners/42`],
    ["the class profile", `${ROOT}/classes/${CLASS_A}`],
    ["the scope document", `${ROOT}/classes/${CLASS_A}/researchers/42`],
  ])("is not readable: %s", async (_, path) => {
    await adminDb().doc(path).set({ platform_id: "https://other.example/" });
    await firebase.assertFails(db("browser").doc(path).get());
  });

  it("is not written onto the runner document", async () => {
    await firebase.assertFails(db("sessionRunner").doc(`${ROOT}/runners/42`).set({ platform_id: "https://other.example/", updated_at: serverTime() }));
  });
});
