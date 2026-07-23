import requireHeaderBearer from "./require-header-bearer";
import bearerTokenAuth from "./bearer-token-auth";

function mockRes() {
  const res: any = {};
  res.error = jest.fn((status: number, message: any) => { res._status = status; res._message = message; return res; });
  return res;
}

describe("requireHeaderBearer (guard in isolation)", () => {
  const run = (req: any) => {
    const res = mockRes();
    const next = jest.fn();
    requireHeaderBearer(req, res, next);
    return { res, next };
  };

  it("401s a scalar query bearer", () => {
    const { res, next } = run({ query: { bearer: "t" }, body: {} });
    expect(res._status).toBe(401);
    expect(next).not.toHaveBeenCalled();
  });

  it("401s an array query bearer", () => {
    const { res } = run({ query: { bearer: ["t"] }, body: {} });
    expect(res._status).toBe(401);
  });

  it("401s an object query bearer", () => {
    const { res } = run({ query: { bearer: { x: "t" } }, body: {} });
    expect(res._status).toBe(401);
  });

  it("401s a body bearer", () => {
    const { res } = run({ query: {}, body: { bearer: "t" } });
    expect(res._status).toBe(401);
  });

  it("calls next() for a header-only request", () => {
    const { res, next } = run({ query: {}, body: {} });
    expect(res.error).not.toHaveBeenCalled();
    expect(next).toHaveBeenCalled();
  });
});

describe("bearerTokenAuth + requireHeaderBearer pipeline (400 vs 401 layering)", () => {
  const TOKEN = "server-secret";
  let prev: string | undefined;

  beforeAll(() => { prev = process.env.AUTH_BEARER_TOKEN; process.env.AUTH_BEARER_TOKEN = TOKEN; });
  afterAll(() => { if (prev === undefined) { delete process.env.AUTH_BEARER_TOKEN; } else { process.env.AUTH_BEARER_TOKEN = prev; } });

  // chain the two raw middleware fns; report the final outcome
  function pipeline(req: any) {
    req.path = req.path || "/bulk_read";
    req.headers = req.headers || {};
    const res = mockRes();
    let reachedHandler = false;
    bearerTokenAuth(req, res, () => {
      requireHeaderBearer(req, res, () => { reachedHandler = true; });
    });
    return { res, reachedHandler };
  }

  it("array query bearer ALONE -> 400 from bearerTokenAuth (guard never runs)", () => {
    const { res } = pipeline({ query: { bearer: ["t"] }, body: {}, headers: {} });
    expect(res._status).toBe(400);
  });

  it("array query bearer + valid header -> 401 from the guard", () => {
    const { res } = pipeline({ query: { bearer: ["t"] }, body: {}, headers: { authorization: `Bearer ${TOKEN}` } });
    expect(res._status).toBe(401);
  });

  it("header-only valid -> reaches the handler", () => {
    const { res, reachedHandler } = pipeline({ query: {}, body: {}, headers: { authorization: `Bearer ${TOKEN}` } });
    expect(res.error).not.toHaveBeenCalled();
    expect(reachedHandler).toBe(true);
  });
});
