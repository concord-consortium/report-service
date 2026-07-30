// Seed the Firestore emulator with the student's demographic answers and mint a
// learner custom token the emulator will accept. Run once (re-run to reset the
// answers) before run.js. Requires the emulator suite to be running.

const fs = require("fs");
const { CONTEXT, ANSWERS, assertLoopbackEmulator, PROJECT_ID, RUN_CONTEXT_FILE } = require("./config");
const { SCENARIOS } = require("./scenarios");

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

  // ⚠️ Clear before writing, and this is not tidiness. The emulator imports and exports its data, so
  // documents written under an older id scheme survive a restart while carrying the same
  // platform_id / resource_link_id / context_id as the ones written below. findAnswerByPrompt throws
  // when more than one document matches a prompt, so a re-seed without this turns a previously green
  // scenario into an unmappable failure that looks like an authoring fault.
  const existing = await answersCol.get();
  for (const doc of existing.docs) {
    await doc.ref.delete();
  }
  console.log(`cleared ${existing.size} existing answer documents`);

  // Each scenario's answers are seeded under that scenario's own launch context, because
  // evaluateCompletion and readDemographics both filter on resource_link_id and context_id. Seeding
  // is a single run that has to hold every scenario's answers at once, so the id carries the
  // SCENARIO: without it every scenario writes the same four ids, the last seeded one wins, and the
  // others are left with no answers under their own launch context. That failure is silent and
  // misleading, reporting "completed 0 of 4 required questions" and every demographic skipped.
  const scenariosNeedingAnswers = Object.entries(SCENARIOS).filter(([, scenario]) => scenario.seedAnswers);
  let seeded = 0;

  for (const [scenarioName, scenario] of scenariosNeedingAnswers) {
    const context = { ...CONTEXT, ...(scenario.context || {}) };
    for (const answer of ANSWERS) {
      const docId = `${context.source_key}-${scenarioName}-ans-${answer.key}`;
      await answersCol.doc(docId).set({
        platform_id: context.platform_id,
        resource_link_id: context.resource_link_id,
        context_id: context.context_id,
        platform_user_id: context.platform_user_id,
        type: "interactive_state",
        question_id: `im-done-${answer.key}`,
        report_state: buildReportState(answer),
      });
      seeded += 1;
    }
    console.log(`seeded ${ANSWERS.length} answers for scenario: ${scenarioName}`);
  }

  const token = await admin.auth().createCustomToken(CONTEXT.platform_user_id, {
    user_type: CONTEXT.user_type,
    platform_user_id: CONTEXT.platform_user_id,
    platform_id: CONTEXT.platform_id,
    class_hash: CONTEXT.context_id,
    context_id: CONTEXT.context_id,
  });

  fs.writeFileSync(RUN_CONTEXT_FILE, JSON.stringify({ token }, null, 2));
  console.log(`\nSeeded ${seeded} answers across ${scenariosNeedingAnswers.length} scenarios and wrote a learner token to ${RUN_CONTEXT_FILE}.`);
  console.log("Next: node run.js [scenario]");
};

main().then(() => process.exit(0)).catch((err) => {
  console.error("seed failed:", err);
  process.exit(1);
});
