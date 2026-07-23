// lift-compile verification.
//
// Proves that the four pure modules (convert.ts, glossary-info.ts,
// page-walk.ts, chat-context.ts) lift into the report-service functions workspace as a CLEAN COPY:
//   1. they COMPILE under functions/tsconfig.json (strict, es2017) — this file importing them is the
//      compile check (ts-jest fails the suite on any type error);
//   2. the full pipeline RUNS on a real v1 LARA resource: convertLegacyResource -> assemblePageContext
//      -> renderPageContext produces sensible orientation + page body text;
//   3. the missing-`plugins` guard holds (a resource with no `plugins` field doesn't throw).
//
// types.ts here is the client's types.ts with its 3 external imports stubbed to `any` (compile-time only).
import { convertLegacyResource } from "./convert";
import { assemblePageContext, renderPageContext } from "./chat-context";
import { getVisiblePages } from "./page-walk";
import { Activity } from "./types";
import * as v1Resource from "./sample-activity-v1.json";

describe("pure-module lift compiles and runs in report-service", () => {
  it("converts a real v1 resource and assembles/renders page context", () => {
    const raw: any = (v1Resource as any).default ?? v1Resource;
    expect(raw.version).toBe(1);

    // call site: version-1 resources go through the lifted convert; v2 pass through.
    const activity = (raw.version === 1 ? convertLegacyResource(raw) : raw) as Activity;
    expect(activity.version).toBe(2);

    const pages = getVisiblePages(activity);
    expect(pages.length).toBeGreaterThan(0);

    const ctx = assemblePageContext(activity, pages[0], {
      sequenceTitle: "Spike Sequence",
      activityTitle: activity.name,
      activityIndex: 1,
      activityCount: 3,
    });
    // orientation is derived from the activity + client hints
    expect(ctx.orientation.pageCount).toBe(pages.length);
    expect(ctx.orientation.sequenceTitle).toBe("Spike Sequence");

    const rendered = renderPageContext(ctx);
    expect(typeof rendered).toBe("string");
    expect(rendered.length).toBeGreaterThan(0);

    // eslint-disable-next-line no-console
    console.log("\nrendered page context (first 600 chars):\n" + rendered.slice(0, 600) + "\n");
  });

  it("convert does not throw when the resource has no `plugins` field", () => {
    const raw: any = (v1Resource as any).default ?? v1Resource;
    const noPlugins = { ...raw };
    delete noPlugins.plugins;
    expect(() => convertLegacyResource(noPlugins)).not.toThrow();
    const activity = convertLegacyResource(noPlugins) as Activity;
    expect(Array.isArray(activity.plugins)).toBe(true);
    expect(activity.plugins.length).toBe(0);
  });
});
