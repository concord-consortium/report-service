import { makeRunPackage, RunPackageDeps, VmRecord, vmUrl } from "./run-package"

const PORTAL = "learn_portal_staging_concord_org"
const USER = "200"
const CLASS = "7be899cf665898097ed1ec57f34b700e156bd4544ffd693f"

function validBody(overrides: any = {}) {
  return {
    scope: { kind: "class", class_hash: CLASS, class_id: 111 },
    package: { name: "class-counts", version: "1.0.0", checksum: "sha256:abc" },
    class_tokens: { "report-service-dev": "class-token" },
    session_token: "session-token",
    report_server_assertion: "assertion",
    firebase_project: "report-service-dev",
    platform_id: "https://learn.portal.staging.concord.org/",
    platform_user_id: 200,
    portal: PORTAL,
    ...overrides
  }
}

function makeRes() {
  const res: any = { statusCode: null, body: null }
  res.error = (status: number, message: any) => { res.statusCode = status; res.body = { error: message }; return res }
  res.success = (payload: any) => { res.statusCode = 200; res.body = payload; return res }
  return res
}

interface Harness {
  deps: RunPackageDeps
  calls: { run: any[]; auth: any[]; posted: any[]; minted: any[]; saved: VmRecord[] }
}

function harness({ remembered = null as VmRecord | null, vmState = "RUNNING", vmImageVersion = "2.0",
                   currentVersion = "2.0", runnerStatus = 202, runnerBody = { package: "class-counts", doc_path: "p" } as any,
                   mintStatus = 201 } = {}): Harness {
  const calls = { run: [] as any[], auth: [] as any[], posted: [] as any[], minted: [] as any[], saved: [] as VmRecord[] }

  const fetchImpl = (async (url: string, init: any) => {
    if (String(url).includes("/api/v1/dashboard-tokens")) {
      calls.minted.push({ url, init })
      return {
        ok: mintStatus < 400,
        status: mintStatus,
        json: async () => ({ token: "forwarded-report-server-token" })
      }
    }
    calls.posted.push({ url, init })
    return { ok: runnerStatus < 400, status: runnerStatus, json: async () => runnerBody }
  }) as any

  const deps: RunPackageDeps = {
    microvms: {
      currentImageVersion: async () => currentVersion,
      get: async () => (vmState === "GONE" ? null : { state: vmState, endpoint: "https://vm.example/", imageVersion: vmImageVersion }),
      run: async (input) => { calls.run.push(input); return { microvmId: "mvm-new", endpoint: "https://new.example/", imageVersion: currentVersion } },
      authHeaders: async (id, port) => { calls.auth.push({ id, port }); return { "x-microvm-auth": "jwe" } }
    },
    loadVm: async () => remembered,
    saveVm: async (_p, _u, record) => { calls.saved.push(record) },
    fetchImpl,
    now: () => Date.now(),
    sleep: async () => { return },
    log: { warn: () => { return }, error: () => { return } },
    config: {
      imageIdentifier: "arn:image",
      executionRoleArn: "arn:role",
      bucket: "researcher-dashboard-runner-staging",
      reportServerUrl: "https://report-server.example.org"
    }
  }
  return { deps, calls }
}

async function call(h: Harness, body: any = validBody()) {
  const res = makeRes()
  await makeRunPackage(h.deps)({ body } as any, res)
  return res
}

describe("runPackage", () => {
  describe("a live VM on the current image", () => {
    it("is reused, and no VM is launched", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" } })
      const res = await call(h)

      expect(res.statusCode).toEqual(200)
      expect(h.calls.run).toHaveLength(0)
      expect(h.calls.saved).toHaveLength(0)
      expect(res.body.microvm_id).toEqual("mvm-1")
    })

    // Minting revokes the researcher's previous token, so asking on a reuse would pull the
    // credential out from under the VM that is already running on it.
    it("does not mint a report-server token", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" } })
      await call(h)

      expect(h.calls.minted).toHaveLength(0)
    })

    it("is reused when suspended, which resume handles", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" }, vmState: "SUSPENDED" })
      await call(h)
      expect(h.calls.run).toHaveLength(0)
    })
  })

  describe("launching", () => {
    it("launches when the researcher has no remembered VM", async () => {
      const h = harness({ remembered: null })
      const res = await call(h)

      expect(h.calls.run).toHaveLength(1)
      expect(h.calls.saved).toEqual([{ microvm_id: "mvm-new", image_version: "2.0" }])
      expect(res.body.microvm_id).toEqual("mvm-new")
    })

    it("relaunches when the remembered VM is gone", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" }, vmState: "GONE" })
      await call(h)
      expect(h.calls.run).toHaveLength(1)
    })

    it("relaunches a terminated VM rather than dispatching to it", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" }, vmState: "TERMINATED" })
      await call(h)
      expect(h.calls.run).toHaveLength(1)
    })

    // A VM running an older image is missing whatever the rebuild fixed, and the runner's
    // sandbox guarantees are part of the image.
    it("relaunches a VM running an older image version", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "1.0" }, vmImageVersion: "1.0", currentVersion: "2.0" })
      await call(h)
      expect(h.calls.run).toHaveLength(1)
    })

    it("carries the researcher's own report-server credential and its url into the VM", async () => {
      const h = harness({ remembered: null })
      await call(h)

      expect(h.calls.minted).toHaveLength(1)
      expect(h.calls.minted[0].init.headers.Authorization).toEqual("Bearer assertion")
      const payload = JSON.parse(h.calls.run[0].runHookPayload)
      expect(payload.report_server_token).toEqual("forwarded-report-server-token")
      expect(payload.report_server_url).toEqual("https://report-server.example.org")
      expect(payload.session_token).toEqual("session-token")
      expect(payload.bucket).toEqual("researcher-dashboard-runner-staging")
      // The launch payload must not carry the shared account's secret name, which is what
      // tells the VM it may not give a package egress.
      expect(payload.secret_name).toBeUndefined()
    })

    // run-microvm returns before the run hook has finished, and a dispatch then reaches a
    // runner that refuses with 409 because it is not up yet.
    it("waits for a launched VM to reach RUNNING before dispatching", async () => {
      const h = harness({ remembered: null })
      const states = ["PENDING", "PENDING", "RUNNING"]
      let i = 0
      h.deps.microvms.get = async () => ({ state: states[Math.min(i++, states.length - 1)], endpoint: "https://vm.example/", imageVersion: "2.0" })

      await call(h)

      expect(i).toBeGreaterThanOrEqual(3)
      expect(h.calls.posted).toHaveLength(1)
    })

    it("fails rather than dispatching when the VM never comes up", async () => {
      const h = harness({ remembered: null })
      h.deps.microvms.get = async () => ({ state: "TERMINATED", endpoint: "https://vm.example/", imageVersion: "2.0" })

      const res = await call(h)

      expect(res.statusCode).toEqual(502)
      expect(h.calls.posted).toHaveLength(0)
    })

    it("refuses without launching when report-server will not mint", async () => {
      const h = harness({ remembered: null, mintStatus: 401 })
      const res = await call(h)

      expect(res.statusCode).toEqual(502)
      expect(h.calls.run).toHaveLength(0)
    })
  })

  describe("dispatch", () => {
    it("posts the scope, package and class tokens to the VM over the auth channel", async () => {
      const h = harness({ remembered: { microvm_id: "mvm-1", image_version: "2.0" } })
      await call(h)

      const post = h.calls.posted[0]
      expect(post.url).toEqual("https://vm.example/run-package")
      expect(h.calls.auth).toEqual([{ id: "mvm-1", port: 8080 }])
      expect(post.init.headers["x-microvm-auth"]).toEqual("jwe")
      const sent = JSON.parse(post.init.body)
      expect(sent.scope.class_hash).toEqual(CLASS)
      expect(sent.class_tokens).toEqual({ "report-service-dev": "class-token" })
      // The runner takes its identity from the launch payload, never from a request body.
      expect(sent.session_token).toBeUndefined()
      expect(h.calls.auth).toEqual([{ id: "mvm-1", port: 8080 }])
    })

    // The runner answers 409 when a package is already running or the VM expires too soon,
    // and the page shows that as queued rather than as a failure.
    it("passes the runner's refusal through with its status", async () => {
      const h = harness({
        remembered: { microvm_id: "mvm-1", image_version: "2.0" },
        runnerStatus: 409,
        runnerBody: { error: "a package is already running on this VM" }
      })
      const res = await call(h)

      expect(res.statusCode).toEqual(409)
      expect(res.body.error).toMatch(/already running/)
    })
  })

  describe("a malformed request", () => {
    const cases: [string, any][] = [
      ["a scope that is not a class", { scope: { kind: "student", class_hash: CLASS, class_id: 111 } }],
      ["a scope with no class_id", { scope: { kind: "class", class_hash: CLASS } }],
      ["a package with no checksum", { package: { name: "class-counts", version: "1.0.0" } }],
      ["no class tokens", { class_tokens: {} }],
      ["no session token", { session_token: "" }],
      ["no assertion", { report_server_assertion: "" }],
      ["no portal", { portal: "" }]
    ]

    cases.forEach(([name, override]) => {
      it(`is refused for ${name}, and nothing is launched`, async () => {
        const h = harness({ remembered: null })
        const res = await call(h, validBody(override))

        expect(res.statusCode).toEqual(400)
        expect(h.calls.run).toHaveLength(0)
        expect(h.calls.posted).toHaveLength(0)
      })
    })
  })
})

// The API returns the endpoint as a bare hostname. fetch refuses a URL without a
// scheme, and the failure reads as a parse error rather than anything about MicroVMs.
describe("vmUrl", () => {
  it("adds https to a bare hostname", () => {
    expect(vmUrl("abc.lambda-microvm.us-east-1.on.aws", "/run-package"))
      .toEqual("https://abc.lambda-microvm.us-east-1.on.aws/run-package")
  })

  it("leaves an endpoint that already has a scheme alone", () => {
    expect(vmUrl("https://abc.example/", "/run-package")).toEqual("https://abc.example/run-package")
  })
})
