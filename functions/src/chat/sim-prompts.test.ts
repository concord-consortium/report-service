// sim-prompt URL matching + page fragment collection.
import { matchSimPrompt, stripVersionSegments, getSimPromptFragments, SIM_PROMPT_RULES } from "./sim-prompts";
import { Page } from "./types";

describe("stripVersionSegments", () => {
  it("removes /branch/<x>/ and /version/<x>/ deploy segments", () => {
    expect(stripVersionSegments("/branch/master/index.html")).toBe("/index.html");
    expect(stripVersionSegments("/version/v3/model.html")).toBe("/model.html");
    expect(stripVersionSegments("/a/branch/foo/b")).toBe("/a/b");
  });
});

describe("matchSimPrompt", () => {
  it("matches a dedicated-subdomain sim by host, version-independent", () => {
    const a = matchSimPrompt("https://wildfire.concord.org/branch/master/index.html");
    const b = matchSimPrompt("https://wildfire.concord.org/version/v2/index.html?run=1");
    expect(a).toBeDefined();
    expect(a).toContain("Wildfire");
    expect(b).toBe(a); // version segment ignored
  });

  it("matches a shared host by host + path prefix (hash folded into path)", () => {
    const frag = matchSimPrompt("https://lab.concord.org/embeddable.html#interactives/samples/1-atomic");
    expect(frag).toBeDefined();
    expect(frag).toContain("Lab");
  });

  it("does not match a shared host without the required path prefix", () => {
    expect(matchSimPrompt("https://lab.concord.org/something-else")).toBeUndefined();
  });

  it("matches CODAP and SageModeler by their own hosts", () => {
    expect(matchSimPrompt("https://codap.concord.org/app?documentId=doc")).toContain("CODAP");
    expect(matchSimPrompt("https://sagemodeler.concord.org/app/?codap=staging")).toContain("SageModeler");
  });

  it("matches Connected Bio by host", () => {
    expect(matchSimPrompt("https://connected-bio-spaces.concord.org/index.html")).toContain("Connected Bio");
  });

  it("falls back to undefined for an unknown host", () => {
    expect(matchSimPrompt("https://unknown-sim.example.com/x")).toBeUndefined();
  });

  it("returns undefined for a non-URL", () => {
    expect(matchSimPrompt("not a url")).toBeUndefined();
  });
});

// Build a minimal page with the given interactive URLs as ManagedInteractive embeddables.
function pageWith(urls: string[]): Page {
  return {
    id: 1,
    is_completion: false,
    is_hidden: false,
    name: "p",
    position: 1,
    show_sidebar: false,
    sidebar: null,
    sidebar_title: null,
    sections: [{
      secondary_column_display_mode: "stacked",
      is_hidden: false,
      secondary_column_collapsible: false,
      layout: "responsive",
      embeddables: urls.map((url, i) => ({
        type: "ManagedInteractive",
        ref_id: `r${i}`,
        is_hidden: false,
        library_interactive: { hash: "h", data: { base_url: url } as any },
      })) as any,
    }],
  };
}

describe("getSimPromptFragments", () => {
  it("collects matched fragments for a page, de-duplicated, in order", () => {
    const page = pageWith([
      "https://wildfire.concord.org/branch/master/index.html",
      "https://wildfire.concord.org/branch/other/index.html", // same sim → deduped
      "https://unknown.example.com/x", // no match → skipped
    ]);
    const frags = getSimPromptFragments(page);
    expect(frags).toHaveLength(1);
    expect(frags[0]).toContain("Wildfire");
  });

  it("returns [] for a page with no matching sims", () => {
    expect(getSimPromptFragments(pageWith(["https://unknown.example.com/x"]))).toEqual([]);
  });

  it("skips hidden embeddables", () => {
    const page = pageWith(["https://wildfire.concord.org/index.html"]);
    (page.sections[0].embeddables[0] as any).is_hidden = true;
    expect(getSimPromptFragments(page)).toEqual([]);
  });
});

// A page whose single ManagedInteractive is the full-screen wrapper, with an optional authored_state.
function fullScreenPage(wrapperUrl: string, authoredState?: string): Page {
  const page = pageWith([wrapperUrl]);
  if (authoredState !== undefined) {
    (page.sections[0].embeddables[0] as any).authored_state = authoredState;
  }
  return page;
}

const FULL_SCREEN = "https://models-resources.concord.org/question-interactives/full-screen/index.html";

describe("full-screen wrapper exception", () => {
  it("unwraps the wrapped app from authored_state.wrappedInteractiveUrl", () => {
    const page = fullScreenPage(
      `${FULL_SCREEN}?foo=bar`,
      JSON.stringify({ version: 1, wrappedInteractiveUrl: "https://codap.concord.org/app?documentId=doc" }));
    const frags = getSimPromptFragments(page);
    expect(frags).toHaveLength(1);
    expect(frags[0]).toContain("CODAP");
  });

  it("falls back to the ?wrappedInteractive= param when authored_state has no wrappedInteractiveUrl", () => {
    const wrapped = encodeURIComponent("https://sagemodeler.concord.org/app/?codap=staging");
    const page = fullScreenPage(`${FULL_SCREEN}?wrappedInteractive=${wrapped}`);
    const frags = getSimPromptFragments(page);
    expect(frags).toHaveLength(1);
    expect(frags[0]).toContain("SageModeler");
  });

  it("is version-independent (branch/version segments in the wrapper path still detected)", () => {
    const page = fullScreenPage(
      "https://models-resources.concord.org/question-interactives/branch/master/full-screen/index.html",
      JSON.stringify({ wrappedInteractiveUrl: "https://codap.concord.org/app" }));
    expect(getSimPromptFragments(page)[0]).toContain("CODAP");
  });

  it("no-ops (no fragment) when the wrapper can't be unwrapped", () => {
    expect(getSimPromptFragments(fullScreenPage(FULL_SCREEN))).toEqual([]);
    expect(getSimPromptFragments(fullScreenPage(FULL_SCREEN, "not json"))).toEqual([]);
  });
});

describe("SIM_PROMPT_RULES seed", () => {
  it("includes the pilot wildfire sim", () => {
    expect(SIM_PROMPT_RULES.some(r => r.host === "wildfire.concord.org")).toBe(true);
  });

  it("includes CODAP, SageModeler, and Connected Bio", () => {
    expect(SIM_PROMPT_RULES.some(r => r.host === "codap.concord.org")).toBe(true);
    expect(SIM_PROMPT_RULES.some(r => r.host === "sagemodeler.concord.org")).toBe(true);
    expect(SIM_PROMPT_RULES.some(r => r.host === "connected-bio-spaces.concord.org")).toBe(true);
  });
});
