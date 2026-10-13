import { BrokerRefusal, sessionPolicy } from "./storage-policy"

const BUCKET = "researcher-dashboard-runner-staging"

describe("sessionPolicy", () => {
  it("is the broker contract, exactly, for one researcher", () => {
    expect(JSON.parse(sessionPolicy(BUCKET, "136"))).toEqual({
      Version: "2012-10-17",
      Statement: [
        { Effect: "Allow", Action: "s3:ListBucket", Resource: `arn:aws:s3:::${BUCKET}`, Condition: { StringLike: { "s3:prefix": "researchers/136/*" } } },
        { Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource: `arn:aws:s3:::${BUCKET}/researchers/136/*` },
        { Effect: "Allow", Action: "s3:GetObject", Resource: `arn:aws:s3:::${BUCKET}/packages/*` }
      ]
    })
  })

  it("names no other researcher's prefix and grants nothing but reads under packages/", () => {
    const statements = JSON.parse(sessionPolicy(BUCKET, "136")).Statement
    const resources = statements.map((s: { Resource: string }) => s.Resource)
    for (const r of resources) {
      expect(r === `arn:aws:s3:::${BUCKET}` || r.startsWith(`arn:aws:s3:::${BUCKET}/researchers/136/`) || r === `arn:aws:s3:::${BUCKET}/packages/*`).toBe(true)
    }
    const onPackages = statements.filter((s: { Resource: string }) => s.Resource.includes("/packages/"))
    expect(onPackages.map((s: { Action: unknown }) => s.Action)).toEqual(["s3:GetObject"])
  })

  it("stays under STS's 2,048-character limit at the longest bucket and id", () => {
    expect(sessionPolicy("b".repeat(63), "9".repeat(20)).length).toBeLessThan(2048)
  })

  it.each(["*", "1*", "?", "0", "-1", "1.5", "", " 1", "1/2", "01"])("refuses the id %j", id => {
    expect(() => sessionPolicy(BUCKET, id)).toThrow(BrokerRefusal)
  })

  it.each(["", "*", "bucket*", "b?", "Bucket", "a", "a..b", "192.168.0.1", "xn--bucket", "sthree-bucket", "bucket-s3alias", "bucket--ol-s3"])("refuses the bucket %j", bucket => {
    expect(() => sessionPolicy(bucket, "136")).toThrow(BrokerRefusal)
  })
})
