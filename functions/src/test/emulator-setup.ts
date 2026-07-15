// Import this at the top of every *.emulator.test.ts. Fails CLOSED so a test can never touch a real project.
import admin from "firebase-admin";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    "FIRESTORE_EMULATOR_HOST is unset — refusing to run emulator tests against a real Firestore project. " +
    "Run via `npm run test:emulator` (firebase emulators:exec)."
  );
}

if (admin.apps.length === 0) {
  admin.initializeApp({ projectId: "report-service-dev" });
}

export const db = admin.firestore();

export async function clearFirestore() {
  const sources = await db.collection("sources").listDocuments();
  await Promise.all(sources.map((s) => db.recursiveDelete(s)));
}
