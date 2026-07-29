// Seed the Firestore emulator with the student's demographic answers and mint a
// learner custom token the emulator will accept. Run once (re-run to reset the
// answers) before run.js. Requires the emulator suite to be running.

const fs = require("fs");
const { CONTEXT, ANSWERS, assertLoopbackEmulator, PROJECT_ID, RUN_CONTEXT_FILE } = require("./config");

// Point the Admin SDK at the emulator BEFORE it initializes, and refuse to run
// if anything points at a non-loopback host (guards against writing to real Firestore).
assertLoopbackEmulator();

const admin = require("firebase-admin");
admin.initializeApp({ projectId: PROJECT_ID });

const buildReportState = (answer) =>
  JSON.stringify({
    authoredState: JSON.stringify({ prompt: answer.prompt, choices: answer.choices }),
    interactiveState: JSON.stringify({ selectedChoiceIds: answer.selectedChoiceIds }),
  });

const main = async () => {
  const db = admin.firestore();
  const answersCol = db.collection(`sources/${CONTEXT.source_key}/answers`);

  for (const answer of ANSWERS) {
    const docId = `${CONTEXT.source_key}-ans-${answer.key}`;
    await answersCol.doc(docId).set({
      platform_id: CONTEXT.platform_id,
      resource_link_id: CONTEXT.resource_link_id,
      context_id: CONTEXT.context_id,
      platform_user_id: CONTEXT.platform_user_id,
      type: "interactive_state",
      question_id: `im-done-${answer.key}`,
      report_state: buildReportState(answer),
    });
    console.log(`seeded answer: ${answer.key}`);
  }

  const token = await admin.auth().createCustomToken(CONTEXT.platform_user_id, {
    user_type: CONTEXT.user_type,
    platform_user_id: CONTEXT.platform_user_id,
    platform_id: CONTEXT.platform_id,
    class_hash: CONTEXT.context_id,
    context_id: CONTEXT.context_id,
  });

  fs.writeFileSync(RUN_CONTEXT_FILE, JSON.stringify({ token }, null, 2));
  console.log(`\nSeeded ${ANSWERS.length} answers and wrote a learner token to ${RUN_CONTEXT_FILE}.`);
  console.log("Next: node run.js [scenario]");
};

main().then(() => process.exit(0)).catch((err) => {
  console.error("seed failed:", err);
  process.exit(1);
});
