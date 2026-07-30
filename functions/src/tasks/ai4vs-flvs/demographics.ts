import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { getClientFirestore } from "../../firebase-client";

export const DIMENSIONS = ["Gender", "Grade", "Module", "Race"] as const;
export type Dimension = typeof DIMENSIONS[number];

/**
 * One pre-test's question wording and answer-choice labels.
 *
 * There is one object per PRE-TEST and it is selected STRUCTURALLY: each step references its own,
 * because the pipeline already selected the step and the step already knows its pre-test. There is
 * deliberately no pilot-keyed table: a key would add a run-time lookup that can miss while
 * selecting nothing the step does not already know, and would couple this to a pilot string another
 * story authors. The property this shape exists for is that a late correction to one pre-test's
 * wording is a one-object edit.
 *
 * What varies by PROGRAM is which dimensions are read, not the wording, and that is resolved at run
 * time from the class word. Two different axes, selected two different ways.
 */
export interface PreTestConfig {
  /** Identifies the pre-test in log lines. */
  label: string;
  /** Case-insensitive substring identifying each dimension's question prompt. */
  prompts: Record<Dimension, string>;
  /**
   * Choice label -> category, matched EXACTLY after trim. Loose matching is rejected: a mis-matched
   * demographic silently places a student in the wrong stratum, corrupting a study arm rather than
   * stopping the pipeline.
   *
   * ⚠️ Gender is binary in every stratum key because the PI's tables have no third gender row, so a
   * non-responder is counted as Female for BALANCING. The answer documents retain the real choice,
   * so analysis can still distinguish non-responders. Also note mapToCategory THROWS on an unmapped
   * gender choice, so any option a pre-test adds and this map lacks blocks every student who picks
   * it.
   */
  genderMap: Record<string, string>;
  gradeMap: Record<string, string>;
  /** The two module titles matched explicitly; every other choice falls to "Other". */
  moduleLabels: { Mod1: string; Mod2: string };
  /** The one race label not reduced to "non-White". */
  raceWhiteLabel: string;
}

/**
 * The three failure kinds are separated by whether RETRYING CAN HELP, because that is the only
 * thing the student-facing message can usefully say.
 */
export type DemographicsOutcome =
  /**
   * One entry per REQUESTED dimension; unrequested dimensions are absent, which is why this is
   * Partial. A caller reading a dimension it did not request gets `undefined`, and a stratum key
   * built from one lands in no table, which every caller treats as a classified failure.
   */
  | { ok: true; categories: Partial<Record<Dimension, string>> }
  /** Answers the student has not given. Retrying helps once they answer; the step names them. */
  | { ok: false; kind: "incomplete"; missing: Dimension[] }
  /**
   * An answer this pre-test's configuration cannot interpret: a duplicated prompt, an unknown
   * choice id, or a choice label absent from a map. All AUTHORING faults, all PERMANENT until the
   * pre-test or this configuration is edited, so no amount of clicking fixes them.
   *
   * The distinction matters most for Gender, which throws rather than defaulting: if a pre-test
   * offers an option its config lacks, every student who picks it is blocked, and telling them to
   * try again would be false. Already logged here with the offending detail.
   */
  | { ok: false; kind: "unmappable" }
  /** A Firestore or transport failure. Genuinely transient, so retrying is honest advice. */
  | { ok: false; kind: "failed" };

export interface DemographicsRequest {
  /** Prefixes log lines, so a failure is attributed to the calling step. */
  logPrefix: string;
  jobPath: string;
  firebaseJwt: string;
  source_key: string;
  platform_id: string;
  resource_link_id: string;
  context_id: string;
  platform_user_id: string;
  preTest: PreTestConfig;
  /** Only these are read. A full-time student never has to answer the flex-only questions. */
  dimensions: readonly Dimension[];
}

/**
 * Parse report_state JSON string → { authoredState, interactiveState }.
 * authoredState and interactiveState are themselves JSON strings that get parsed.
 */
const parseReportState = (reportState: string) => {
  let parsed: any;
  try {
    parsed = JSON.parse(reportState);
  } catch (e) {
    throw new Error(`Failed to parse report_state as JSON: ${(e as Error).message}`);
  }

  let authoredState: any;
  try {
    authoredState = JSON.parse(parsed.authoredState);
  } catch (e) {
    throw new Error(`Failed to parse report_state.authoredState as JSON: ${(e as Error).message}`);
  }

  let interactiveState: any;
  try {
    interactiveState = JSON.parse(parsed.interactiveState);
  } catch (e) {
    throw new Error(`Failed to parse report_state.interactiveState as JSON: ${(e as Error).message}`);
  }

  return { authoredState, interactiveState };
};

/**
 * Find the answer doc matching a prompt substring.
 * Returns the parsed authoredState and interactiveState.
 * Fails if zero or multiple docs match.
 */
const findAnswerByPrompt = (
  answerDocs: Array<{ data: any }>,
  dimension: Dimension,
  preTest: PreTestConfig,
  logPrefix: string,
): { authoredState: any; interactiveState: any } => {
  const substring = preTest.prompts[dimension];
  const matches: Array<{ authoredState: any; interactiveState: any }> = [];

  for (const doc of answerDocs) {
    try {
      const parsed = parseReportState(doc.data.report_state);
      if (parsed.authoredState.prompt?.toLowerCase().includes(substring.toLowerCase())) {
        matches.push(parsed);
      }
    } catch (err) {
      // Skip docs with unparseable report_state, but log for debugging
      functions.logger.warn(`${logPrefix}: skipping answer doc with unparseable report_state`, err);
    }
  }

  if (matches.length === 0) {
    const err = new Error(`No answer doc found for ${dimension} (prompt substring: "${substring}")`);
    (err as any).isMissingAnswer = true;
    throw err;
  }
  if (matches.length > 1) {
    throw new Error(`Multiple answer docs (${matches.length}) matched ${dimension} (prompt substring: "${substring}")`);
  }

  return matches[0];
};

/**
 * Resolve selectedChoiceIds to content text via authoredState.choices.
 */
const resolveChoices = (
  authoredState: any,
  interactiveState: any,
  dimension: Dimension,
): string[] => {
  const selectedIds: string[] = interactiveState.selectedChoiceIds || [];
  if (selectedIds.length === 0) {
    const err = new Error(`Empty selectedChoiceIds for ${dimension}`);
    (err as any).isMissingAnswer = true;
    throw err;
  }

  const choices: Array<{ id: string; content: string }> = authoredState.choices || [];
  return selectedIds.map(id => {
    const choice = choices.find(c => c.id === id);
    if (!choice) {
      throw new Error(`Choice ID "${id}" not found in authoredState.choices for ${dimension}`);
    }
    return choice.content.trim();
  });
};

/**
 * Map resolved choice content text to a category for the given dimension.
 */
const mapToCategory = (dimension: Dimension, choiceTexts: string[], preTest: PreTestConfig): string => {
  switch (dimension) {
    case "Gender": {
      const text = choiceTexts[0];
      const category = preTest.genderMap[text];
      if (!category) {
        throw new Error(`Unmapped Gender choice: "${text}"`);
      }
      return category;
    }
    case "Grade": {
      const text = choiceTexts[0];
      const category = preTest.gradeMap[text];
      if (!category) {
        throw new Error(`Unmapped Grade choice: "${text}"`);
      }
      return category;
    }
    case "Module": {
      // Default fallback: anything not Mod1 or Mod2 → Other
      const text = choiceTexts[0];
      if (text === preTest.moduleLabels.Mod1) {
        return "Mod1";
      }
      if (text === preTest.moduleLabels.Mod2) {
        return "Mod2";
      }
      return "Other";
    }
    case "Race": {
      // Binary reduction: only-White → White, otherwise → non-White
      const hasOnlyWhite = choiceTexts.length === 1 && choiceTexts[0] === preTest.raceWhiteLabel;
      return hasOnlyWhite ? "White" : "non-White";
    }
  }
};

/**
 * Query the student's answers and resolve each requested dimension to its category.
 *
 * The answers query spans the whole SEQUENCE, because a multi-activity sequence shares one
 * resource_link_id. That is what makes a demographic question duplicated across two activities
 * hazardous: findAnswerByPrompt throws when more than one answer matches a prompt.
 */
export const readDemographics = async (request: DemographicsRequest): Promise<DemographicsOutcome> => {
  const { logPrefix, jobPath, firebaseJwt, source_key, platform_id, resource_link_id } = request;
  const { context_id, platform_user_id, preTest, dimensions } = request;

  let firestoreCleanup: (() => Promise<void>) | undefined;
  try {
    const { firestore, cleanup } = await getClientFirestore(firebaseJwt);
    firestoreCleanup = cleanup;

    const answersRef = collection(firestore, `sources/${source_key}/answers`);
    const q = query(
      answersRef,
      where("platform_id", "==", platform_id),
      where("resource_link_id", "==", resource_link_id),
      where("context_id", "==", context_id),
      where("platform_user_id", "==", platform_user_id),
    );
    const snapshot = await getDocs(q);
    const answerDocs = snapshot.docs.map(doc => ({ data: doc.data() }));

    const categories: Partial<Record<Dimension, string>> = {};
    const missing: Dimension[] = [];

    for (const dim of dimensions) {
      try {
        const { authoredState, interactiveState } = findAnswerByPrompt(answerDocs, dim, preTest, logPrefix);
        const choiceTexts = resolveChoices(authoredState, interactiveState, dim);
        categories[dim] = mapToCategory(dim, choiceTexts, preTest);
      } catch (error: any) {
        if (error.isMissingAnswer) {
          missing.push(dim);
        } else {
          // Everything thrown by the three resolvers is an authoring fault, so this whole inner
          // catch is `unmappable`; only the outer catch below is a retryable `failed`.
          functions.logger.error(`${logPrefix}: ${error.message} for ${jobPath} (${preTest.label})`);
          return { ok: false, kind: "unmappable" };
        }
      }
    }

    if (missing.length > 0) {
      functions.logger.error(
        `${logPrefix}: missing or incomplete answers for ${missing.join(", ")} for user ${platform_user_id} at ${jobPath}`,
      );
      return { ok: false, kind: "incomplete", missing };
    }

    return { ok: true, categories };
  } catch (error) {
    // ⚠️ The words "unexpected error" are load-bearing: the spring step's suite asserts the
    // Firestore-throw log contains them, so any other wording fails there.
    functions.logger.error(`${logPrefix}: unexpected error reading demographics for ${jobPath}`, error);
    return { ok: false, kind: "failed" };
  } finally {
    try {
      if (firestoreCleanup) {
        await firestoreCleanup();
      }
    } catch (cleanupErr) {
      functions.logger.warn(`${logPrefix}: cleanup failed`, cleanupErr);
    }
  }
};
