// Pure page-context assembler.
//
// Turns (activity, page, orientationHints) into the PAGE-DERIVED portion of the tutor system
// prompt (orientation block + page body). This module is intentionally pure and dependency-light
// so it can be lifted verbatim into the report-service Firebase Function (the same trick used for
// convert.ts): it imports ONLY `../types` (compile-time, erased) and `./page-walk` (pure). Do NOT
// import React, firebase-db, url-query, activity-utils, or embeddable-utils here — those carry
// browser/React/Firebase deps that would break the Node lift.
//
// It deliberately contains NO generic tutor prompt and NO sim-prompt map — those are server-only
// and concatenated in the function around this output.
import { Activity, Page, EmbeddableType } from "./types";
import { getVisiblePages, getVisibleSections, getVisibleEmbeddables, isQuestion } from "./page-walk";

export type PageContextBodyItem =
  | { kind: "text"; content: string }                          // Embeddable::Xhtml.content (raw)
  | { kind: "image"; name: string }                            // name/title only — no pixels, no URL
  | { kind: "question"; name?: string; authoredState: string }; // raw authored_state (definition only)

export interface PageContext {
  orientation: {
    sequenceTitle?: string | null;
    activityTitle: string;
    // `activityIndex` is 0-based (matching app state / the wire doc field); rendering adds 1 for
    // the "N" in "Activity N of M". Present only in a sequence.
    activityIndex?: number;
    activityCount?: number;
    pageNumber: number;        // 1-based, N of M over *visible* pages (derived from the activity)
    pageCount: number;
    pageTitle?: string | null;
  };
  body: PageContextBodyItem[];
}

// Orientation hints are passed IN (not derived from a Sequence object): the function has no
// Sequence (it fetches only the single activity), and the client's debug/live path supplies these
// display-only strings from app state. Page N of M + activityTitle fall back to the activity
// itself; sequence/activity lines come from these hints. `activityIndex` is the 0-based index into
// the sequence (matching app state); rendering adds 1 for the displayed "Activity N of M".
export interface OrientationHints {
  sequenceTitle?: string | null;   // omit when not in a sequence
  activityTitle?: string;          // falls back to activity.name
  activityIndex?: number;          // 0-based index into the sequence; only in a sequence
  activityCount?: number;          // M, only in a sequence
}

const imagePathRegex = /\.(png|jpe?g|gif|svg|webp|bmp)$/i;

// Resolve an interactive's URL the same way managed-interactive does (base_url || url).
const getEmbeddableUrl = (embeddable: EmbeddableType): string | undefined => {
  if (embeddable.type === "ManagedInteractive") {
    return embeddable.library_interactive?.data?.base_url || embeddable.library_interactive?.data?.url || undefined;
  }
  if (embeddable.type === "MwInteractive") {
    return embeddable.base_url || embeddable.url || undefined;
  }
  return undefined;
};

// Strip query/hash so we test only the path — a sim URL like `index.html?bg=scene.png` is NOT an image.
const urlPath = (url: string): string => url.split(/[?#]/)[0];

// A non-question interactive whose URL path points at a static image is treated as an "image block"
// (contributes name/title only — no pixels, no URL).
const isImageEmbeddable = (embeddable: EmbeddableType): boolean => {
  const url = getEmbeddableUrl(embeddable);
  return !!url && imagePathRegex.test(urlPath(url));
};

export function assemblePageContext(
  activity: Activity, page: Page, hints: OrientationHints = {}
): PageContext {
  const visiblePages = getVisiblePages(activity);
  const pageIdx = visiblePages.findIndex(p => p.id === page.id);
  const pageNumber = pageIdx >= 0 ? pageIdx + 1 : 1;

  const body: PageContextBodyItem[] = [];
  // Authored order: visible sections, then visible embeddables within each section.
  for (const section of getVisibleSections(page)) {
    for (const embeddable of getVisibleEmbeddables(section)) {
      if (isQuestion(embeddable)) {
        body.push({
          kind: "question",
          name: embeddable.name || undefined,
          authoredState: typeof embeddable.authored_state === "string" ? embeddable.authored_state : "",
        });
      } else if (embeddable.type === "Embeddable::Xhtml") {
        body.push({ kind: "text", content: embeddable.content ?? "" });
      } else if (isImageEmbeddable(embeddable)) {
        body.push({ kind: "image", name: embeddable.name || "" });
      }
      // else: non-question sims, plugins, media-library blocks are omitted from the page body
      // (sim awareness arrives later via sim prompts + forwarded logs).
    }
  }

  return {
    orientation: {
      sequenceTitle: hints.sequenceTitle ?? null,
      activityTitle: hints.activityTitle || activity.name,
      activityIndex: hints.activityIndex,
      activityCount: hints.activityCount,
      pageNumber,
      pageCount: visiblePages.length,
      pageTitle: page.name ?? null,
    },
    body,
  };
}

// Render a PageContext to the plain-text block the model receives. Kept separate from assembly so
// the debug view and the function render identically. This is ONLY the page-derived portion; the
// generic tutor prompt and any sim-prompt fragment are concatenated around it server-side.
export function renderPageContext(ctx: PageContext): string {
  const { orientation: o, body } = ctx;
  const lines: string[] = [];

  if (o.sequenceTitle) {
    lines.push(`Sequence: "${o.sequenceTitle}"`);
  }
  // "Activity N of M" only when in a sequence (both hint fields present). activityIndex is 0-based.
  if (o.activityIndex !== undefined && o.activityCount !== undefined) {
    lines.push(`Activity ${o.activityIndex + 1} of ${o.activityCount}: "${o.activityTitle}"`);
  }
  lines.push(`Page ${o.pageNumber} of ${o.pageCount}${o.pageTitle ? `: "${o.pageTitle}"` : ""}`);

  lines.push("");
  lines.push("Page content (authored order, visible content only):");
  if (body.length === 0) {
    lines.push("(this page has no authored text, images, or questions)");
  }
  for (const item of body) {
    switch (item.kind) {
      case "text":
        lines.push(`- [text] ${item.content}`);
        break;
      case "image":
        lines.push(`- [image] ${item.name}`);
        break;
      case "question":
        lines.push(`- [question]${item.name ? ` ${item.name}` : ""}`);
        lines.push(`  authored_state: ${item.authoredState}`);
        break;
    }
  }

  return lines.join("\n");
}
