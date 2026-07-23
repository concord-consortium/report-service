// PURE page-walk helpers. This module imports ONLY `../types` (compile-time,
// erased at build) — no React, no firebase-db, no url-query, no lara-interactive-api — so
// `chat-context.ts` (which imports these) has a genuinely liftable import graph and can be
// copied verbatim into the report-service Firebase Function. Do NOT add impure imports here.
//
// The bodies below are the single source of truth for the visible-content walk + question
// detection; `activity-utils.ts` and `embeddable-utils.ts` re-export them so existing call
// sites are unaffected.
import { Activity, Page, SectionType, EmbeddableType } from "./types";

export const getVisiblePages = (activity: Activity) => {
  return activity.pages.filter(page => !page.is_hidden);
};

export const getVisibleSections = (page: Page) => {
  return page.sections.filter(section => !section.is_hidden);
};

export const getVisibleEmbeddables = (section: SectionType) => {
  return section.embeddables.filter((embeddable: EmbeddableType) => !embeddable.is_hidden);
};

// Moved verbatim from embeddable-utils.ts:23 — the body uses only fields on the embeddable
// union (no external deps), which is why it belongs in this pure module.
export const isQuestion = (embeddable: EmbeddableType, options?: {ignoreHideQuestionNumber?: boolean}) => {
  let enable_learner_state = false;
  let hide_question_number = false;
  const ignoreHideQuestionNumber = options?.ignoreHideQuestionNumber ?? false;

  if (embeddable.type === "MwInteractive") {
    enable_learner_state = !!embeddable.enable_learner_state;
    hide_question_number = !!embeddable.hide_question_number;
  }
  if (embeddable.type === "ManagedInteractive") {
    enable_learner_state = !!(embeddable.library_interactive?.data.enable_learner_state);
    hide_question_number = !!(embeddable.inherit_hide_question_number ? embeddable.library_interactive?.data.hide_question_number : embeddable.custom_hide_question_number);
  }

  return enable_learner_state && (ignoreHideQuestionNumber || !hide_question_number);
};
