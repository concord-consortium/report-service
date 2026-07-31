// portal-reads consumes only the transport, so mock the whole module rather than
// requireActual-ing it (which would pull in firebase-functions for no benefit).
const mockPortalTokenFetch = jest.fn();
jest.mock("./portal-api", () => ({
  portalTokenFetch: (...args: any[]) => mockPortalTokenFetch(...args),
}));

// Must import after jest.mock
import { lookupClassByWord, resolveOriginOffering } from "./portal-reads";

const PORTAL_URL = "https://learn.concord.org";
const TOKEN = "minted-teacher-token-sentinel";

/** Mirrors rigse's classes#info get_info shape (anonymized students, real teacher names). */
const getInfoBody = {
  id: 30001,
  uri: "https://learn.concord.org/api/v1/classes/30001",
  name: "FT-fall-2026-A",
  class_hash: "hash-a",
  class_word: "FT-fall-2026-A",
  teachers: [{ id: "https://learn.concord.org/users/7", user_id: 7, first_name: "Ada", last_name: "Lovelace" }],
  students: [{ id: "https://learn.concord.org/users/9", user_id: 9, first_name: "Student", last_name: "9" }],
  offerings: [
    {
      id: 555,
      name: "Fall Pre-test",
      active: true,
      locked: false,
      metadata: [{ user_id: 9, locked: false }],
      url: "https://learn.concord.org/api/v1/offerings/555",
      external_url: "https://activity.concord.org/activities/12",
    },
  ],
};

describe("lookupClassByWord", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: getInfoBody });
  });

  it("requests classes/info with the url-encoded class word and the given token", async () => {
    await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall 2026/A");

    expect(mockPortalTokenFetch).toHaveBeenCalledWith({
      portalUrl: PORTAL_URL,
      path: "/api/v1/classes/info?class_word=FT-fall%202026%2FA",
      method: "GET",
      token: TOKEN,
    });
  });

  it("maps a get_info body to a PortalClass", async () => {
    const result = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

    expect(result.status).toBe(200);
    expect(result.class).toEqual({
      id: 30001,
      name: "FT-fall-2026-A",
      classWord: "FT-fall-2026-A",
      teachers: getInfoBody.teachers,
      offerings: [
        {
          id: 555,
          name: "Fall Pre-test",
          active: true,
          locked: false,
          metadata: [{ user_id: 9, locked: false }],
          offeringApiUrl: "https://learn.concord.org/api/v1/offerings/555",
          activityUrl: "https://activity.concord.org/activities/12",
        },
      ],
    });
  });

  it("maps activityUrl from external_url, not from url", async () => {
    const result = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

    expect(result.class!.offerings[0].activityUrl).toBe("https://activity.concord.org/activities/12");
    expect(result.class!.offerings[0].offeringApiUrl).toBe("https://learn.concord.org/api/v1/offerings/555");
  });

  it("defaults missing teachers/offerings/metadata to empty arrays", async () => {
    mockPortalTokenFetch.mockResolvedValue({
      status: 200,
      data: { id: 1, name: "No Lists", class_word: "no-lists", offerings: [{ id: 2, name: "o" }] },
    });

    const result = await lookupClassByWord(PORTAL_URL, TOKEN, "no-lists");

    expect(result.class!.teachers).toEqual([]);
    expect(result.class!.offerings[0]).toEqual({
      id: 2,
      name: "o",
      active: false,
      locked: false,
      metadata: [],
      offeringApiUrl: undefined,
      activityUrl: undefined,
    });
  });

  it("returns status only on a non-2xx", async () => {
    mockPortalTokenFetch.mockResolvedValue({
      status: 400,
      data: { success: false, message: "The requested class was not found" },
    });

    const result = await lookupClassByWord(PORTAL_URL, TOKEN, "nope");

    expect(result).toEqual({ status: 400 });
  });

  it("returns status only when a 2xx body carries no id", async () => {
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { name: "no id" } });

    const result = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

    expect(result).toEqual({ status: 200 });
  });

  // A 2xx is not by itself a resolved class. These values flow into side effects: `id` is minted
  // against and posted as clazz_id (a null one would enroll into class "null"), and `name` is
  // rendered into the teacher-notification email (a missing one would read "Enrolled in
  // undefined"). rigse answers an unknown word with a 400, so these are type-boundary cases.
  describe("rejects a malformed 2xx body rather than resolving it", () => {
    const malformed: Array<[string, Record<string, unknown>]> = [
      ["a null id", { ...getInfoBody, id: null }],
      ["a non-finite id", { ...getInfoBody, id: Number.NaN }],
      ["a blank string id", { ...getInfoBody, id: "   " }],
      ["a missing name", { ...getInfoBody, name: undefined }],
      ["a blank name", { ...getInfoBody, name: "  " }],
      ["a non-string name", { ...getInfoBody, name: 42 }],
      ["a missing class_word", { ...getInfoBody, class_word: undefined }],
      ["a blank class_word", { ...getInfoBody, class_word: "" }],
    ];

    it.each(malformed)("returns status only for %s", async (_label, data) => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data });

      const result = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

      expect(result).toEqual({ status: 200 });
      expect(result.class).toBeUndefined();
    });

    it("still accepts a numeric-string id, matching OriginOffering.clazzId", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { ...getInfoBody, id: "30001" } });

      const result = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

      expect(result.class!.id).toBe("30001");
    });
  });

  it("never places the token in its return value", async () => {
    const success = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");
    mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { token: TOKEN } });
    const failure = await lookupClassByWord(PORTAL_URL, TOKEN, "FT-fall-2026-A");

    expect(JSON.stringify(success)).not.toContain(TOKEN);
    expect(JSON.stringify(failure)).not.toContain(TOKEN);
  });
});

describe("resolveOriginOffering", () => {
  const offeringBody = {
    id: 678,
    clazz_id: 90210,
    class_word: "FL-spring-2026-origin",
    name: "Origin Offering",
    active: true,
    locked: false,
  };

  beforeEach(() => {
    jest.clearAllMocks();
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: offeringBody });
  });

  it("reads clazz_id and class_word from a single offerings#show response", async () => {
    const result = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(mockPortalTokenFetch).toHaveBeenCalledWith({
      portalUrl: PORTAL_URL,
      path: "/api/v1/offerings/678",
      method: "GET",
      token: TOKEN,
    });
    expect(result).toEqual({
      status: 200,
      offering: { clazzId: 90210, classWord: "FL-spring-2026-origin" },
    });
  });

  it("leaves classWord undefined when the response omits it", async () => {
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { id: 678, clazz_id: 90210 } });

    const result = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(result.offering).toEqual({ clazzId: 90210, classWord: undefined });
  });

  it("returns status only when a 2xx body carries no clazz_id", async () => {
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { id: 678 } });

    const result = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(result).toEqual({ status: 200 });
  });

  // The same isUsableId the class read applies, so the two reads in this file agree on more than
  // null. A blank id would be skipped by readStepOutputField and posted as class_id: "" by
  // send-email's fallback; a non-scalar would be posted as "[object Object]".
  // The explicit tuple type is required by jest 24's it.each typings, as index.test.ts's own table is.
  const UNUSABLE_IDS: Array<[string, any]> = [
    ["a blank string", ""],
    ["whitespace", "   "],
    ["an object", { id: 90210 }],
    ["a non-finite number", Number.NaN],
  ];
  it.each(UNUSABLE_IDS)("returns status only when a 2xx body carries %s as clazz_id", async (_label, clazzId) => {
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { id: 678, clazz_id: clazzId } });

    const result = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(result).toEqual({ status: 200 });
  });

  it("returns status only on a non-2xx", async () => {
    mockPortalTokenFetch.mockResolvedValue({ status: 404, data: null });

    const result = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(result).toEqual({ status: 404 });
  });

  it("never places the token in its return value", async () => {
    const success = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");
    mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { token: TOKEN } });
    const failure = await resolveOriginOffering(PORTAL_URL, TOKEN, "678");

    expect(JSON.stringify(success)).not.toContain(TOKEN);
    expect(JSON.stringify(failure)).not.toContain(TOKEN);
  });
});
