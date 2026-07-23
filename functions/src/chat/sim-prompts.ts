// URL-keyed per-sim prompt fragments (developer-maintained, server-only).
//
// The tutor is made sim-aware WITHOUT any LARA authoring by injecting an optional prompt fragment
// keyed off the interactive's URL. Matching is host/subdomain-first (real sims have dedicated
// subdomains like `wildfire.concord.org`), extended to host + path/hash prefix for shared hosts
// (`lab.concord.org#interactives/<slug>`, `models-resources.concord.org/question-interactives/<type>/`).
// Version segments (`/branch/<x>/`, `/version/<x>/`) are stripped — they're deploy details, not
// identity. Ordered list, first match per URL, graceful fallback (no match → generic + page context).
// A page with multiple sims concatenates the matched fragments.
import { Page, EmbeddableType } from "./types";
import { getVisibleSections, getVisibleEmbeddables } from "./page-walk";

export interface SimPromptRule {
  // Exact host match, e.g. "wildfire.concord.org".
  host: string;
  // Optional path/hash prefix for SHARED hosts (matched after version-stripping + leading `#`/`/`
  // normalization), e.g. "interactives/" or "question-interactives/". Omit for dedicated-subdomain sims.
  pathPrefix?: string;
  fragment: string;
}

// Developer-maintained, ordered. Seeded with the pilot's Wildfire sim + a couple of illustrative
// shared-host examples. Extend this list to make more sims tutor-aware; no code change is required.
export const SIM_PROMPT_RULES: SimPromptRule[] = [
  {
    host: "wildfire.concord.org",
    fragment: [
      "The interactive on this page is the Wildfire Explorer (wildfire.concord.org). Across 2–3 zones the",
      "student sets terrain (Plains, Foothills, Mountains), vegetation (Grass, Shrub, Forest — options depend",
      "on terrain), a drought index (No, Mild, Medium, or Severe Drought), and wind (direction and 0–30 MPH",
      "speed); they place one or more sparks and run the fire, optionally using Fireline or Helitack during a",
      "run. The \"Acres Burned vs. Time\" graph shows one line per zone — a steeper line means the fire spread",
      "faster. Treat the model as the student's investigation tool: prompt them to set conditions, run it, and",
      "compare outcomes across zones. If a question is about how the interface works, answer it directly;",
      "reserve guiding/Socratic questions for scientific reasoning. When the student ASKS about a run's",
      "results, help them read and compare the zones — reporting observed on-screen values like acres burned",
      "is fine; just don't hand them the page's conclusion. Zone indices in the activity logs are 0-based",
      "(0, 1, 2), but the student sees them labeled Zone 1, Zone 2, Zone 3 in the UI — always refer to a zone",
      "by its 1-based UI label (add 1 to the logged index, so logged zone 0 is the student's \"Zone 1\").",
    ].join(" "),
  },
  {
    host: "codap.concord.org",
    fragment: [
      "The interactive on this page is CODAP (Common Online Data Analysis Platform, codap.concord.org) — a",
      "data-analysis environment. The student works with data in tables (cases and attributes) and drags",
      "attributes onto axes to build graphs (dot plots, scatter plots, histograms), and may add maps,",
      "sliders, calculators, or other components. Treat CODAP as the student's tool for exploring data and",
      "finding patterns: prompt them to graph attributes, look for trends, relationships, clusters, or",
      "outliers, and tie what they see back to the page's question. If a question is about how CODAP's",
      "interface works (making a graph, dragging an attribute, adding a component), answer it directly;",
      "reserve guiding/Socratic questions for interpreting the data. When the student ASKS about a graph,",
      "help them read and describe it — naming a trend or an outlier they can see is fine — but don't hand",
      "them the page's conclusion.",
    ].join(" "),
  },
  {
    host: "sagemodeler.concord.org",
    fragment: [
      "The interactive on this page is SageModeler (sagemodeler.concord.org) — a systems-modeling tool. The",
      "student builds a model by creating variables (nodes) and connecting them with links that say how one",
      "variable affects another (an increase in A makes B increase or decrease, 'a little' / 'a lot' /",
      "'about the same'), then runs the model to see how the variables behave over time or as a simulation.",
      "Treat the model as the student's tool for expressing and testing their thinking about a system:",
      "prompt them to identify the variables, define the relationships between them, run the model, and",
      "compare its behavior to what they expect or observe. If a question is about how SageModeler's",
      "interface works (adding a variable, drawing a link, setting a relationship, running the model),",
      "answer it directly; reserve guiding/Socratic questions for the science of the system being modeled.",
      "Help them reason about cause-and-effect chains and feedback loops rather than telling them the",
      "\"correct\" model.",
    ].join(" "),
  },
  {
    host: "connected-bio-spaces.concord.org",
    fragment: [
      "The interactive on this page is Connected Bio (connected-bio-spaces.concord.org), a multi-level model",
      "of a mouse population and its genetics with several linked spaces: a Populations view where mice live",
      "in an environment and natural selection plays out (fur color that matches the environment is harder",
      "for predators to spot, so coloration shifts over generations); a Breeding view where the student",
      "breeds pairs of mice and tracks how alleles combine into genotype and phenotype (fur color) across",
      "offspring; an Organism view that connects an individual mouse down to the cellular/molecular level",
      "(the hormones and melanin that set fur color); and Charts that graph the data. Treat it as the",
      "student's investigation tool: prompt them to run the population, breed mice, or change the",
      "environment, then observe and compare outcomes and tie them back to the page's question. If a",
      "question is about how the interface works, answer it directly; reserve guiding/Socratic questions for",
      "the biology (selection, inheritance, genotype vs phenotype, the molecular basis of a trait). When the",
      "student ASKS about a run or a cross, help them read and describe what they see — allele or trait",
      "frequencies, which mice survived or bred — without handing them the page's conclusion.",
    ].join(" "),
  },
  {
    host: "lab.concord.org",
    pathPrefix: "interactives/",
    fragment: [
      "The interactive on this page is a Concord Consortium Lab model. Encourage the student to run it and",
      "describe what they observe, and tie those observations back to the page's question.",
    ].join(" "),
  },
];

// Remove deploy-detail version segments so a sim's identity is version-independent.
export function stripVersionSegments(path: string): string {
  return path.replace(/\/(branch|version)\/[^/]+\//g, "/");
}

// Normalize an interactive URL to { host, candidates } for matching. A shared-host sim's identifying
// slug can live in the pathname (models-resources.concord.org/question-interactives/<type>/) OR in the
// hash (lab.concord.org#interactives/<slug>), so BOTH are offered as candidate keys (version segments
// stripped, leading `#`/`/` trimmed). A pathPrefix rule matches if ANY candidate starts with the prefix.
function normalizeUrl(urlStr: string): { host: string; candidates: string[] } | undefined {
  let u: URL;
  try {
    u = new URL(urlStr);
  } catch (e) {
    return undefined;
  }
  const trim = (s: string) => stripVersionSegments(s).replace(/^[#/]+/, "");
  const candidates = [trim(u.pathname), trim(u.hash || "")].filter(Boolean);
  return { host: u.hostname, candidates };
}

// Return the fragment for a single interactive URL, or undefined when nothing matches.
export function matchSimPrompt(urlStr: string): string | undefined {
  const normalized = normalizeUrl(urlStr);
  if (!normalized) return undefined;
  for (const rule of SIM_PROMPT_RULES) {
    if (rule.host !== normalized.host) continue;
    if (rule.pathPrefix) {
      const prefix = rule.pathPrefix.replace(/^[#/]+/, "");
      if (!normalized.candidates.some(c => c.startsWith(prefix))) continue;
    }
    return rule.fragment;
  }
  return undefined;
}

// The full-screen question-interactive
// (models-resources.concord.org/.../question-interactives/full-screen/) is a WRAPPER: its own base_url
// is the full-screen app, and the REAL embedded app (CODAP, SageModeler, …) lives in the wrapper's
// authored state. CODAP and SageModeler are almost always embedded this way (so the app can go
// fullscreen), so sim rules must match the WRAPPED app, not the wrapper. When we see the full-screen
// interactive we unwrap it, mirroring the full-screen runtime's own resolution order (question-interactives
// full-screen/app.tsx): authored_state.wrappedInteractiveUrl first, then the wrapper URL's
// ?wrappedInteractive= param.
const FULL_SCREEN_PATH_PREFIX = "question-interactives/full-screen";

function isFullScreenWrapperUrl(urlStr: string): boolean {
  const normalized = normalizeUrl(urlStr);
  if (!normalized) return false;
  return normalized.host === "models-resources.concord.org"
    && normalized.candidates.some(c => c.startsWith(FULL_SCREEN_PATH_PREFIX));
}

function unwrapFullScreenUrl(wrapperUrl: string, authoredState?: string | null): string | undefined {
  // 1. authored_state.wrappedInteractiveUrl — the canonical field the full-screen runtime uses first.
  if (authoredState) {
    try {
      const wrapped = JSON.parse(authoredState)?.wrappedInteractiveUrl;
      if (typeof wrapped === "string" && wrapped) return wrapped;
    } catch (e) {
      // malformed authored_state → fall through to the URL-param fallback
    }
  }
  // 2. Fallback: the wrapper URL's own ?wrappedInteractive= param (the runtime's own fallback).
  try {
    const wrapped = new URL(wrapperUrl).searchParams.get("wrappedInteractive");
    if (wrapped) return wrapped;
  } catch (e) {
    // not a parseable URL
  }
  return undefined;
}

// Resolve an interactive's URL the same way managed-interactive / chat-context does (base_url || url),
// applying the full-screen-wrapper exception so the wrapped app (not the wrapper) drives sim matching.
function getEmbeddableUrl(embeddable: EmbeddableType): string | undefined {
  let url: string | undefined;
  if (embeddable.type === "ManagedInteractive") {
    url = embeddable.library_interactive?.data?.base_url || embeddable.library_interactive?.data?.url || undefined;
  } else if (embeddable.type === "MwInteractive") {
    url = embeddable.base_url || embeddable.url || undefined;
  } else {
    return undefined;
  }
  if (url && isFullScreenWrapperUrl(url)) {
    // If we can't unwrap, keep the wrapper URL — no sim rule matches it, so it's a graceful no-op.
    return unwrapFullScreenUrl(url, embeddable.authored_state) ?? url;
  }
  return url;
}

// Collect the interactive URLs authored on a page (visible embeddables, authored order).
export function collectInteractiveUrls(page: Page): string[] {
  const urls: string[] = [];
  for (const section of getVisibleSections(page)) {
    for (const embeddable of getVisibleEmbeddables(section)) {
      const url = getEmbeddableUrl(embeddable);
      if (url) urls.push(url);
    }
  }
  return urls;
}

// Matched, de-duplicated sim-prompt fragments for a page, in authored order. Empty when no sim matches.
export function getSimPromptFragments(page: Page): string[] {
  const fragments: string[] = [];
  const seen = new Set<string>();
  for (const url of collectInteractiveUrls(page)) {
    const fragment = matchSimPrompt(url);
    if (fragment && !seen.has(fragment)) {
      seen.add(fragment);
      fragments.push(fragment);
    }
  }
  return fragments;
}
