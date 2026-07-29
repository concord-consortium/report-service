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
  classifyPortalFailure,
  messageForBucket,
  PortalFailureBucket,
  RELOAD_MESSAGE,
  TELL_TEACHER_MESSAGE,
  validatePortalHost,
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

describe("classifyPortalFailure", () => {
  it("buckets a mint 422 with reason expired to reload", () => {
    expect(classifyPortalFailure({ status: 422, reason: "expired" })).toBe(PortalFailureBucket.Reload);
  });

  it("buckets non-expired 4xx failures to tell-teacher", () => {
    expect(classifyPortalFailure({ status: 400 })).toBe(PortalFailureBucket.TellTeacher);
    expect(classifyPortalFailure({ status: 401 })).toBe(PortalFailureBucket.TellTeacher);
    expect(classifyPortalFailure({ status: 403 })).toBe(PortalFailureBucket.TellTeacher);
    expect(classifyPortalFailure({ status: 404 })).toBe(PortalFailureBucket.TellTeacher);
    expect(classifyPortalFailure({ status: 422, reason: "signature" })).toBe(PortalFailureBucket.TellTeacher);
    expect(classifyPortalFailure({ status: 422 })).toBe(PortalFailureBucket.TellTeacher);
  });

  it("buckets 2xx-non-success, 5xx, and thrown (status 0) to generic", () => {
    expect(classifyPortalFailure({ status: 200 })).toBe(PortalFailureBucket.Generic);
    expect(classifyPortalFailure({ status: 500 })).toBe(PortalFailureBucket.Generic);
    expect(classifyPortalFailure({ status: 0 })).toBe(PortalFailureBucket.Generic);
  });
});

describe("messageForBucket", () => {
  it("returns the shared reload and tell-teacher messages", () => {
    expect(messageForBucket(PortalFailureBucket.Reload, "fallback")).toBe(RELOAD_MESSAGE);
    expect(messageForBucket(PortalFailureBucket.TellTeacher, "fallback")).toBe(TELL_TEACHER_MESSAGE);
  });

  it("returns the caller's fallback for the generic bucket", () => {
    expect(messageForBucket(PortalFailureBucket.Generic, "please try again")).toBe("please try again");
  });
});

describe("validatePortalHost", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
    delete process.env.FUNCTIONS_EMULATOR;
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org";
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it("accepts a listed https host and returns its normalized origin", () => {
    expect(validatePortalHost("https://learn.concord.org")).toEqual({
      ok: true,
      host: "learn.concord.org",
      origin: "https://learn.concord.org",
    });
  });

  it("accepts a bare origin with a trailing slash, normalizing it to the origin", () => {
    expect(validatePortalHost("https://learn.concord.org/")).toEqual({
      ok: true,
      host: "learn.concord.org",
      origin: "https://learn.concord.org",
    });
  });

  it("matches a listed host case-insensitively", () => {
    process.env.TRUSTED_PORTAL_HOSTS = "Learn.Concord.Org";
    expect(validatePortalHost("https://learn.concord.org")).toEqual({
      ok: true,
      host: "learn.concord.org",
      origin: "https://learn.concord.org",
    });
  });

  it("rejects a platform_id carrying a path", () => {
    expect(validatePortalHost("https://learn.concord.org/foo")).toEqual({ ok: false, host: "learn.concord.org" });
  });

  it("rejects a platform_id carrying a query string", () => {
    expect(validatePortalHost("https://learn.concord.org?x=1")).toEqual({ ok: false, host: "learn.concord.org" });
  });

  it("rejects an https host carrying an explicit port", () => {
    expect(validatePortalHost("https://learn.concord.org:8443")).toEqual({
      ok: false,
      host: "learn.concord.org:8443",
    });
  });

  it("rejects an unlisted host", () => {
    expect(validatePortalHost("https://evil.com")).toEqual({ ok: false, host: "evil.com" });
  });

  it("rejects a credential-embedding lookalike by its real hostname", () => {
    expect(validatePortalHost("https://learn.concord.org@evil.com")).toEqual({ ok: false, host: "evil.com" });
  });

  it("rejects a non-URL value", () => {
    expect(validatePortalHost("not a url")).toEqual({ ok: false });
    expect(validatePortalHost(undefined)).toEqual({ ok: false });
    expect(validatePortalHost("")).toEqual({ ok: false });
  });

  it("rejects http on a non-loopback host", () => {
    expect(validatePortalHost("http://learn.concord.org")).toEqual({ ok: false, host: "learn.concord.org" });
  });

  it("accepts http://localhost (with its port) only when listed and running under the emulator", () => {
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org,localhost";
    process.env.FUNCTIONS_EMULATOR = "true";
    expect(validatePortalHost("http://localhost:3000")).toEqual({
      ok: true,
      host: "localhost:3000",
      origin: "http://localhost:3000",
    });
  });

  it("rejects http://localhost when not running under the emulator", () => {
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org,localhost";
    delete process.env.FUNCTIONS_EMULATOR;
    expect(validatePortalHost("http://localhost:3000")).toEqual({ ok: false, host: "localhost:3000" });
  });

  it("rejects http://localhost when localhost is not listed even under the emulator", () => {
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org";
    process.env.FUNCTIONS_EMULATOR = "true";
    expect(validatePortalHost("http://localhost:3000")).toEqual({ ok: false, host: "localhost:3000" });
  });
});
