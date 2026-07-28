const mockGetRequestHeaders = jest.fn();
const mockGetIdTokenClient = jest.fn();

jest.mock("google-auth-library", () => ({
  GoogleAuth: jest.fn().mockImplementation(() => ({
    getIdTokenClient: (...args: any[]) => mockGetIdTokenClient(...args),
  })),
}));

const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
const mockLoggerWarn = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: (...args: any[]) => mockLoggerWarn(...args),
  },
}));

// Must import after jest.mock
import {
  portalOidcFetch,
  mintScopedPortalToken,
  getScopedPortalToken,
  createPortalTokenCache,
} from "./portal-api";

// Mock global fetch
const originalFetch = global.fetch;
const mockFetch = jest.fn();
(global as any).fetch = mockFetch;

const defaultOptions = {
  portalUrl: "https://learn.concord.org",
  path: "/api/v1/offerings/123/update_student_metadata",
  method: "PUT" as const,
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: "locked=true&user_id=27",
};

describe("portalOidcFetch", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.clearAllMocks();
    process.env = { ...originalEnv };
    delete process.env.FUNCTIONS_EMULATOR;
    delete process.env.PORTAL_OIDC_TOKEN;
    mockGetIdTokenClient.mockResolvedValue({
      getRequestHeaders: mockGetRequestHeaders,
    });
    mockGetRequestHeaders.mockResolvedValue({ Authorization: "Bearer prod-token" });
    mockFetch.mockResolvedValue({
      status: 200,
      json: () => Promise.resolve({ locked: true }),
    });
  });

  afterAll(() => {
    process.env = originalEnv;
    global.fetch = originalFetch;
  });

  describe("production mode", () => {
    it("uses GoogleAuth to get an OIDC token", async () => {
      const result = await portalOidcFetch(defaultOptions);

      expect(mockGetIdTokenClient).toHaveBeenCalledWith("https://learn.concord.org");
      expect(mockGetRequestHeaders).toHaveBeenCalled();
      expect(mockFetch).toHaveBeenCalledWith(
        "https://learn.concord.org/api/v1/offerings/123/update_student_metadata",
        {
          method: "PUT",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            Authorization: "Bearer prod-token",
          },
          body: "locked=true&user_id=27",
        }
      );
      expect(result).toEqual({ status: 200, data: { locked: true } });
    });
  });

  describe("emulator mode", () => {
    it("uses PORTAL_OIDC_TOKEN environment variable", async () => {
      process.env.FUNCTIONS_EMULATOR = "true";
      process.env.PORTAL_OIDC_TOKEN = "emulator-test-token";

      const result = await portalOidcFetch(defaultOptions);

      expect(mockGetIdTokenClient).not.toHaveBeenCalled();
      expect(mockFetch).toHaveBeenCalledWith(
        "https://learn.concord.org/api/v1/offerings/123/update_student_metadata",
        expect.objectContaining({
          headers: expect.objectContaining({
            Authorization: "Bearer emulator-test-token",
          }),
        })
      );
      expect(result).toEqual({ status: 200, data: { locked: true } });
    });

    it("throws if PORTAL_OIDC_TOKEN is not set", async () => {
      process.env.FUNCTIONS_EMULATOR = "true";

      await expect(portalOidcFetch(defaultOptions)).rejects.toThrow(
        "PORTAL_OIDC_TOKEN environment variable is required"
      );
      expect(mockFetch).not.toHaveBeenCalled();
    });
  });

  describe("non-JSON response", () => {
    it("returns null data when response is not JSON", async () => {
      mockFetch.mockResolvedValue({
        status: 500,
        json: () => Promise.reject(new Error("not JSON")),
      });

      const result = await portalOidcFetch(defaultOptions);

      expect(result).toEqual({ status: 500, data: null });
    });
  });
});

const mockMint = (status: number, data: any) =>
  mockFetch.mockResolvedValue({ status, json: () => Promise.resolve(data) });

describe("mintScopedPortalToken", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.clearAllMocks();
    process.env = { ...originalEnv };
    delete process.env.FUNCTIONS_EMULATOR;
    delete process.env.PORTAL_OIDC_TOKEN;
    mockGetIdTokenClient.mockResolvedValue({ getRequestHeaders: mockGetRequestHeaders });
    mockGetRequestHeaders.mockResolvedValue({ Authorization: "Bearer oidc-token" });
    (global as any).fetch = mockFetch;
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it("mints an origin token, OIDC-authed, with a derived origin description", async () => {
    mockMint(201, { token: "minted-origin" });

    const result = await mintScopedPortalToken({
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher",
      pilot: "spring-2026",
    });

    expect(result).toEqual({ ok: true, token: "minted-origin", status: 201 });
    const [url, opts] = mockFetch.mock.calls[0];
    expect(url).toBe("https://learn.concord.org/api/v1/jwt/oidc_mint");
    expect(opts.headers.Authorization).toBe("Bearer oidc-token");
    const body = JSON.parse(opts.body);
    expect(body.firebase_token).toBe("student-fb-token");
    expect(body.token_type).toBe("teacher");
    expect(body.description).toBe("spring-2026:origin");
    expect(body.class_id).toBeUndefined();
  });

  it("mints a cross-class token with class_id and a class-scoped description", async () => {
    mockMint(201, { token: "minted-class" });

    const result = await mintScopedPortalToken({
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher",
      classId: "555",
      pilot: "spring-2026",
    });

    expect(result).toEqual({ ok: true, token: "minted-class", status: 201 });
    const body = JSON.parse(mockFetch.mock.calls[0][1].body);
    expect(body.class_id).toBe("555");
    expect(body.description).toBe("spring-2026:class-555");
  });

  it("returns { ok: false, reason } on a 422 with details.reason", async () => {
    mockMint(422, { success: false, details: { reason: "expired" } });

    const result = await mintScopedPortalToken({
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher",
      pilot: "spring-2026",
    });

    expect(result).toEqual({ ok: false, status: 422, reason: "expired" });
  });

  it("never logs the minted token value on the success path", async () => {
    mockMint(201, { token: "super-secret-jwt" });

    await mintScopedPortalToken({
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher",
      pilot: "spring-2026",
    });

    const allLogArgs = [
      ...mockLoggerInfo.mock.calls,
      ...mockLoggerError.mock.calls,
      ...mockLoggerWarn.mock.calls,
    ].flat();
    const serialized = JSON.stringify(allLogArgs);
    expect(serialized).not.toContain("super-secret-jwt");
  });
});

describe("getScopedPortalToken caching", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.clearAllMocks();
    process.env = { ...originalEnv };
    delete process.env.FUNCTIONS_EMULATOR;
    delete process.env.PORTAL_OIDC_TOKEN;
    mockGetIdTokenClient.mockResolvedValue({ getRequestHeaders: mockGetRequestHeaders });
    mockGetRequestHeaders.mockResolvedValue({ Authorization: "Bearer oidc-token" });
    (global as any).fetch = mockFetch;
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it("mints once per key and reuses across steps, minting a separate token per class", async () => {
    let nextToken = 0;
    mockFetch.mockImplementation(() =>
      Promise.resolve({ status: 201, json: () => Promise.resolve({ token: `minted-${nextToken++}` }) })
    );
    const cache = createPortalTokenCache();
    const base = {
      cache,
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher" as const,
      pilot: "spring-2026",
    };

    const origin1 = await getScopedPortalToken(base);
    const classResult = await getScopedPortalToken({ ...base, classId: "555" });
    const origin2 = await getScopedPortalToken(base);

    expect(mockFetch).toHaveBeenCalledTimes(2);
    expect(origin1.token).toBe("minted-0");
    expect(classResult.token).toBe("minted-1");
    expect(origin2).toEqual({ ok: true, token: "minted-0", status: 200 });
  });

  it("does not cache a failed mint", async () => {
    mockMint(422, { success: false, details: { reason: "signature" } });
    const cache = createPortalTokenCache();
    const params = {
      cache,
      portalUrl: "https://learn.concord.org",
      firebaseToken: "student-fb-token",
      tokenType: "teacher" as const,
      pilot: "spring-2026",
    };

    const first = await getScopedPortalToken(params);
    const second = await getScopedPortalToken(params);

    expect(first.ok).toBe(false);
    expect(second.ok).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });
});
