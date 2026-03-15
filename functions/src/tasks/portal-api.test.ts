const mockGetRequestHeaders = jest.fn();
const mockGetIdTokenClient = jest.fn();

jest.mock("google-auth-library", () => ({
  GoogleAuth: jest.fn().mockImplementation(() => ({
    getIdTokenClient: (...args: any[]) => mockGetIdTokenClient(...args),
  })),
}));

// Must import after jest.mock
import { portalOidcFetch } from "./portal-api";

// Mock global fetch
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
