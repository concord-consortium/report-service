import { initializeApp, deleteApp, FirebaseApp } from "firebase/app";
import { getFirestore, connectFirestoreEmulator, Firestore } from "firebase/firestore";
import { getAuth, connectAuthEmulator, signInWithCustomToken } from "firebase/auth";

// Project configs — matches activity-player/src/firebase-db.ts
const configurations: Record<string, Record<string, string>> = {
  "report-service-dev": {
    apiKey: atob("QUl6YVN5Q3Z4S1d1WURnSjRyNG84SmVOQU9ZdXN4MGFWNzFfWXVF"),
    authDomain: "report-service-dev.firebaseapp.com",
    databaseURL: "https://report-service-dev.firebaseio.com",
    projectId: "report-service-dev",
    storageBucket: "report-service-dev.appspot.com",
    messagingSenderId: "402218300971",
    appId: "1:402218300971:web:32b7266ef5226ff7",
  },
  "report-service-pro": {
    apiKey: atob("QUl6YVN5Qm1OU2EyVXozRGFFd0tjbHN2SFBCd2Z1Y1NtWldBQXpn"),
    authDomain: "report-service-pro.firebaseapp.com",
    databaseURL: "https://report-service-pro.firebaseio.com",
    projectId: "report-service-pro",
    storageBucket: "report-service-pro.appspot.com",
    messagingSenderId: "22386066971",
    appId: "1:22386066971:web:e0cdec7cb0f0893a8a5abe",
  },
};

/**
 * Create an authenticated client SDK Firestore instance scoped to the given JWT.
 * Returns the Firestore instance and a cleanup function that signs out and
 * deletes the app instance (ensuring auth state isolation between invocations).
 */
export async function getClientFirestore(jwt: string): Promise<{
  firestore: Firestore;
  cleanup: () => Promise<void>;
}> {
  const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
  if (!projectId) {
    throw new Error("Could not determine GCP project ID from environment");
  }

  const config = configurations[projectId];
  if (!config) {
    throw new Error(`No Firebase client config for project: ${projectId}`);
  }

  // Use a unique app name to avoid conflicts with admin SDK and other invocations
  const appName = `client-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const app: FirebaseApp = initializeApp(config, appName);

  const auth = getAuth(app);

  // Connect to emulators when running locally
  if (process.env.FUNCTIONS_EMULATOR === "true") {
    const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "localhost:9090";
    const [fsHost, fsPort] = firestoreHost.split(":");
    connectFirestoreEmulator(getFirestore(app), fsHost, parseInt(fsPort, 10));

    const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST || "localhost:9099";
    connectAuthEmulator(auth, `http://${authHost}`, { disableWarnings: true });
  }

  try {
    await signInWithCustomToken(auth, jwt);
  } catch (err) {
    await deleteApp(app);
    throw err;
  }

  const firestore = getFirestore(app);

  const cleanup = async () => {
    try {
      await auth.signOut();
    } finally {
      await deleteApp(app);
    }
  };

  return { firestore, cleanup };
}
