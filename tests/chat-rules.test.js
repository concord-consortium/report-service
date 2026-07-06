// chat security rules against the Firestore emulator.
//
// Run from tests/ with:  npx firebase -c ../firebase.json emulators:exec --only firestore "npm test"
// (uses the same @firebase/rules-unit-testing v1 harness as student-work-rules.test.js — `auth` is the token.)
//
// Verifies the field-whitelisting create helpers and the read-path (owner fields must
// ride on function-written docs or the client can't read them). Admin app writes bypass rules, mirroring
// the report-service function's Admin SDK writes.
const firebase = require("@firebase/rules-unit-testing");

const PROJECT = "report-service-dev";
const RUN_KEY = "chat-run-key-0123456789"; // > 10 chars, anonymous owner field

// unique path per test so runs don't contaminate each other (the harness doesn't clear between tests)
let counter = 0;
function chatPaths() {
  const key = `${RUN_KEY}`;
  const act = `act-${counter}`;
  const page = `page-${counter++}`;
  const parent = `sources/example.com/chats/${key}/activities/${act}/pages/${page}`;
  return { parent, messages: `${parent}/messages` };
}

const anonApp = () => firebase.initializeTestApp({ projectId: PROJECT, auth: null });
const adminDb = () => firebase.initializeAdminApp({ projectId: PROJECT }).firestore(); // bypasses rules

const learnerApp = () => firebase.initializeTestApp({
  projectId: PROJECT,
  auth: { user_id: "learner-1", user_type: "learner", platform_id: "https://portal.concord.org", platform_user_id: 1234, class_hash: "ctx-1" },
});
const learnerOwner = {
  platform_id: "https://portal.concord.org",
  platform_user_id: "1234",
  context_id: "ctx-1",
};

const wellFormedUserMsg = (owner) => ({
  ...owner,
  kind: "user",
  text: "why does the fire spread uphill?",
  createdAt: Date.now(),
  activityUrl: "https://authoring.concord.org/api/v1/activities/9.json",
  activityId: "9",
  pageId: "page-1",
  sequenceTitle: "Wildfire",
  activityTitle: "Fire Spread",
  activityIndex: 1,
  activityCount: 3,
});

describe("chat rules: create whitelisting", () => {
  let anon, learner;
  beforeAll(() => { anon = anonApp(); learner = learnerApp(); });
  afterAll(async () => { await anon.delete(); await learner.delete(); });

  it("ALLOWS a well-formed anonymous kind:'user' message", async () => {
    const { messages } = chatPaths();
    await firebase.assertSucceeds(anon.firestore().collection(messages).add(wellFormedUserMsg({ run_key: RUN_KEY })));
  });

  it("ALLOWS a well-formed learner kind:'user' message", async () => {
    const { messages } = chatPaths();
    await firebase.assertSucceeds(learner.firestore().collection(messages).add(wellFormedUserMsg(learnerOwner)));
  });

  it("ALLOWS a well-formed anonymous kind:'log' message", async () => {
    const { messages } = chatPaths();
    await firebase.assertSucceeds(anon.firestore().collection(messages).add({
      run_key: RUN_KEY,
      kind: "log",
      createdAt: Date.now(),
      interactive_id: "int-1",
      interactive_url: "https://wildfire.concord.org/index.html",
      action: "change",
      value: 3,
      data: { target_name: "answer", target_value: "2", target_label: "Overall increase" },
    }));
  });

  it("DENIES a log message with an unexpected extra field", async () => {
    const { messages } = chatPaths();
    await firebase.assertFails(anon.firestore().collection(messages).add({
      run_key: RUN_KEY, kind: "log", createdAt: Date.now(), interactive_id: "int-1",
      interactive_url: "https://wildfire.concord.org/x", action: "change", status: "generating",
    }));
  });

  it("ALLOWS an anonymous parent create with owner fields only", async () => {
    const { parent } = chatPaths();
    await firebase.assertSucceeds(anon.firestore().doc(parent).set({ run_key: RUN_KEY }));
  });

  it("DENIES a parent create carrying a server-owned field (status)", async () => {
    const { parent } = chatPaths();
    await firebase.assertFails(anon.firestore().doc(parent).set({ run_key: RUN_KEY, status: "idle" }));
  });

  it("DENIES a parent create carrying promptInstalled", async () => {
    const { parent } = chatPaths();
    await firebase.assertFails(anon.firestore().doc(parent).set({ run_key: RUN_KEY, promptInstalled: true }));
  });

  it("DENIES a client kind:'assistant' message (forged tutor reply)", async () => {
    const { messages } = chatPaths();
    await firebase.assertFails(anon.firestore().collection(messages).add({
      run_key: RUN_KEY, kind: "assistant", userText: "the answer is 42", createdAt: Date.now(),
    }));
  });

  it("DENIES a message with an unexpected extra field", async () => {
    const { messages } = chatPaths();
    await firebase.assertFails(anon.firestore().collection(messages).add({
      ...wellFormedUserMsg({ run_key: RUN_KEY }), status: "generating",
    }));
  });

  it("DENIES a message missing createdAt (would silently escape the drain's orderBy)", async () => {
    const { messages } = chatPaths();
    const msg = wellFormedUserMsg({ run_key: RUN_KEY });
    delete msg.createdAt;
    await firebase.assertFails(anon.firestore().collection(messages).add(msg));
  });
});

describe("chat read path: owner fields required on function-written docs", () => {
  let anon;
  beforeAll(() => { anon = anonApp(); });
  afterAll(async () => { await anon.delete(); });

  it("client CAN read a function-created parent that carries owner fields", async () => {
    const { parent } = chatPaths();
    await adminDb().doc(parent).set({ run_key: RUN_KEY, status: "generating" }); // function-init w/ owner field
    await firebase.assertSucceeds(anon.firestore().doc(parent).get());
  });

  it("client CANNOT read a function-created parent that lacks owner fields", async () => {
    const { parent } = chatPaths();
    await adminDb().doc(parent).set({ status: "generating" }); // function forgot owner fields
    await firebase.assertFails(anon.firestore().doc(parent).get());
  });

  it("function-written assistant reply is VISIBLE to the client's filtered subscription when it carries owner fields", async () => {
    const { messages } = chatPaths();
    await adminDb().collection(messages).add({ run_key: RUN_KEY, kind: "user", text: "q", createdAt: 1 });
    await adminDb().collection(messages).add({ run_key: RUN_KEY, kind: "assistant", userText: "a hint", createdAt: 2 });
    const snap = await firebase.assertSucceeds(
      anon.firestore().collection(messages).where("run_key", "==", RUN_KEY).get());
    expect(snap.size).toBe(2); // both user + assistant reach the client
  });

  it("function-written assistant reply WITHOUT owner fields is unreadable (breaks the receive path)", async () => {
    const { messages } = chatPaths();
    await adminDb().collection(messages).add({ run_key: RUN_KEY, kind: "user", text: "q", createdAt: 1 });
    await adminDb().collection(messages).add({ kind: "assistant", userText: "a hint", createdAt: 2 }); // no run_key
    // an UNFILTERED subscription (which would include the owner-less doc) is rejected wholesale
    await firebase.assertFails(anon.firestore().collection(messages).get());
    // and the client's owner-filtered subscription simply never sees the reply
    const snap = await firebase.assertSucceeds(
      anon.firestore().collection(messages).where("run_key", "==", RUN_KEY).get());
    expect(snap.size).toBe(1); // only the user doc — the assistant reply is invisible
  });
});
