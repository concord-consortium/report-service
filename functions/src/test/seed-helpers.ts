import admin from "firebase-admin";
import { db } from "./emulator-setup";

const { Timestamp, FieldValue } = admin.firestore;

interface SeedAnswerOpts {
  source: string;
  remote_endpoint: string;
  question_id: string;
  answer_id: string;
  platform_id: string;
  platform_user_id: string;
  resource_link_id: string;
  context_id?: string;
  interactiveState?: unknown;   // will be double-JSON-encoded into report_state
  extra?: Record<string, unknown>;
}

// Faithful answer doc (matches activity-player createAnswerDoc). report_state is DOUBLE-encoded.
export function answerDoc(o: SeedAnswerOpts) {
  return {
    id: o.answer_id,
    question_id: o.question_id,
    type: "interactive_state",
    source_key: o.source,
    tool_id: "activity-player",
    resource_url: `https://example.com/${o.resource_link_id}`,
    context_id: o.context_id ?? "class-hash-1",
    run_key: "",
    remote_endpoint: o.remote_endpoint,
    platform_id: o.platform_id,
    platform_user_id: o.platform_user_id,
    resource_link_id: o.resource_link_id,
    created: new Date().toUTCString(),
    interactive_state_history_id: "",
    report_state: JSON.stringify({
      interactiveState: JSON.stringify(o.interactiveState ?? { foo: "bar" }),
    }),
    ...(o.extra ?? {}),
  };
}

export async function seedAnswer(o: SeedAnswerOpts) {
  await db.doc(`sources/${o.source}/answers/${o.answer_id}`).set(answerDoc(o));
}

// One history snapshot: metadata doc (sortable created_at Timestamp) + state doc (full answer-doc copy).
export async function seedHistory(o: SeedAnswerOpts & {
  history_id: string;
  created_at?: { seconds: number; nanoseconds: number };  // omit -> serverTimestamp (shape fixtures)
}) {
  const created_at = o.created_at
    ? new Timestamp(o.created_at.seconds, o.created_at.nanoseconds)
    : FieldValue.serverTimestamp();

  await db.doc(`sources/${o.source}/interactive_state_histories/${o.history_id}`).set({
    id: o.history_id,
    answer_id: o.answer_id,
    question_id: o.question_id,
    state_type: "full",
    created_at,
    platform_id: o.platform_id,
    platform_user_id: o.platform_user_id,
    resource_link_id: o.resource_link_id,
    context_id: o.context_id ?? "class-hash-1",
  });

  await db.doc(`sources/${o.source}/interactive_state_history_states/${o.history_id}`).set(answerDoc(o));
}
