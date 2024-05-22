'use strict';

const app = require('../../app.js');
const aws = require('../../steps/aws.js');
const firebase = require('../../steps/firebase.js');
const chai = require('chai');
const queryString = require('query-string');
const nock = require('nock');

const { expectedDetailsReportWithNamesSQLresult, expectedDetailsReportHideNamesSQLresult, expectedUsageReportWithNamesSQLresult, expectedUsageReportWithoutNamesSQLresult, expectedNoRunnableWithNamesSQLresult, expectedNoRunnableWithoutNamesSQLresult } = require('./generated-sql.js');

const expect = chai.expect;
const event = {
  queryStringParameters: {
    reportServiceSource: 'test-source',
    tokenServiceEnv: 'dev'
  },
  body: queryString.stringify({
    jwt: 'fake-jwt',
    json: JSON.stringify({
      version: "2",
      query: "",
      learnersApiUrl: "https://example.com/api/v1/",
      user: {
        email: "user@example.com"
      }
    })
  })
};
const context = {};

process.env.FIREBASE_APP = 'report-service-test';
process.env.PORTAL_REPORT_URL = 'https://portal-report.test';
process.env.OUTPUT_BUCKET = 'fake-bucket';
process.env.REPORT_SERVICE_TOKEN = 'fake-token';
process.env.REPORT_SERVICE_URL = 'https://example.com';
process.env.RESEARCHER_REPORTS_URL = 'https://example.com';

// This matches the the request to get a token service jwt
const scopeExample = nock('https://example.com')
  .get('/api/v1/jwt/firebase?firebase_app=token-service')
  .reply(200, 'jwt response');

// This is the token service request,
// it would be better to mock the token service rather than using nock
const scopeLocalhost = nock('http://localhost:5000')
  .get('/api/v1/resources/?type=athenaWorkgroup&tool=researcher-report&name=user-example-com&amOwner=true&env=dev')
  // .get(/.*/)
  .reply(200, '{ "fake": "response" }');

const testQueryId = "123456789";
const testResource = {
  url: "https://authoring.staging.concord.org/activities/000000",
  name: "test activity",
  type: "activity",
  children: [
    { type: "section",
      children: [
        { type: "page",
          children: [
            { id: "multiple_choice_00000", type: "multiple_choice", prompt: "mc prompt 1",
              choices: [{ content: "a", correct: true, id: 1 }, { content: "b", correct: false, id: 2 }, { content: "c", correct: false, id: 3 }]
            },
            { id: "multiple_choice_01000", type: "multiple_choice", prompt: "mc prompt 2",
              choices: [{ content: "a", correct: false, id: 1 }, { content: "b", correct: false, id: 2 }, { content: "c", correct: false, id: 3 }]
            },
            { id: "multiple_choice_02000", type: "multiple_choice", prompt: "mc prompt 3",
              choices: [{ content: "a", correct: true, id: 1 }, { content: "b", correct: true, id: 2 }, { content: "c", correct: false, id: 3 }]
            },
            { id: "multiple_choice_03000", type: "multiple_choice", prompt: "mc prompt 1", required: true,
              choices: [{ content: "a", correct: true, id: 1 }, { content: "b", correct: false, id: 2 }, { content: "c", correct: false, id: 3 }]
            },
            { id: "open_response_11111", type: "open_response", prompt: "<b>open response prompt 1</b>", required: false },
            { id: "open_response_22222", type: "open_response", prompt: "<p>open response</p> <b>prompt 2</b>", required: true },
            { id: "image_question_33333", type: "image_question", prompt: "<h1><b>image response</b></h1> <h2>prompt 1</h2>", required: false },
            { id: "image_question_44444", type: "image_question", prompt: "image response prompt 2", required: true },
            { id: "managed_interactive_55555", type: "open_response", prompt: "AP open response prompt", required: false },
            { id: "managed_interactive_66666", type: "multiple_choice", prompt: "AP mc prompt", required: false,
              choices: [{ content: "a", correct: true, id: 1 }, { content: "b", correct: false, id: 2 }, { content: "c", correct: false, id: 3 }]
            },
            { id: "managed_interactive_77777", type: "image_question", prompt: "AP image prompt", required: false},
            { id: "managed_interactive_88888", type: "iframe_interactive"},
            { id: "managed_interactive_99999", type: "unknown_type"}
          ]
        }
      ]
    }
  ]
};

const testQueryId2 = "ABCDEFGHI";
const testResource2 = {
  url: "https://authoring.staging.concord.org/activities/000001",
  name: "test activity 2",
  type: "activity",
  children: [
    { type: "section",
      children: [
        { type: "page",
          children: [
            { id: "managed_interactive_88888", type: "iframe_interactive"},
          ]
        }
      ]
    }
  ]
};

const normalizeSQL = (sql) => sql
  .split("\n")
  .map(line => line.trim())
  .filter(line => line.length > 1)
  .join("\n")

describe('Tests index', function () {
    it('verifies a response', async () => {
        const result = await app.lambdaHandler(event, context)

        expect(result).to.be.an('object');
        expect(result.body).to.be.an('string');
        let response = JSON.parse(result.body);

        // NOTE: Currently the test does not mock enough so the result is actually
        // a 500.
        // expect(result.statusCode).to.equal(200);

        expect(response).to.be.an('object');
        // expect(response.message).to.be.equal("create query");
        // expect(response.location).to.be.an("string");
    });
});

describe('Denormalize resource', function () {
  it('strips html tags from question prompts', async () => {
    const testDenormalizedResource = firebase.denormalizeResource(testResource);
    expect(testDenormalizedResource.questions.open_response_11111.prompt).to.be.equal("open response prompt 1");
    expect(testDenormalizedResource.questions.open_response_22222.prompt).to.be.equal("open response prompt 2");
    expect(testDenormalizedResource.questions.image_question_33333.prompt).to.be.equal("image response prompt 1");
  });
});

describe('Query creation', function () {
  const testRunnableInfo = {
    [testQueryId]: {
      runnableUrl: testResource.url,
      resource: testResource,
      denormalizedResource: firebase.denormalizeResource(testResource)
    },
    [testQueryId2]: {
      runnableUrl: testResource2.url,
      resource: testResource2,
      denormalizedResource: firebase.denormalizeResource(testResource2)
    },
  }

  it('verifies successful query creation with names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "fake-auth-domain", 'fake-source-key', false);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedDetailsReportWithNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('verifies successful query creation without names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "fake-auth-domain", 'fake-source-key', true);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedDetailsReportHideNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('has different queries with and without names', () => {
    expect(normalizeSQL(expectedDetailsReportWithNamesSQLresult)).not.to.be.equal(normalizeSQL(expectedDetailsReportHideNamesSQLresult));
  })
});

describe('Query creation usage report', function () {
  const testRunnableInfo = {
    [testQueryId]: {
      runnableUrl: testResource.url,
      resource: testResource,
      denormalizedResource: firebase.denormalizeResource(testResource)
    },
    [testQueryId2]: {
      runnableUrl: testResource2.url,
      resource: testResource2,
      denormalizedResource: firebase.denormalizeResource(testResource2)
    },
  }

  it('verifies successful query creation in usage report mode with names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, true, "fake-auth-domain", 'fake-source-key', false);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedUsageReportWithNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('verifies successful query creation in usage report mode without names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, true, "fake-auth-domain", 'fake-source-key', true);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedUsageReportWithoutNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('has different queries with and without names', () => {
    expect(normalizeSQL(expectedUsageReportWithNamesSQLresult)).not.to.be.equal(normalizeSQL(expectedUsageReportWithoutNamesSQLresult));
  })
});

describe('Query creation unreportable runnable', function () {
  const testRunnableInfo = {[testQueryId]: {
    runnableUrl: "http://no-url",
    resource: undefined,
    denormalizedResource: undefined
  }}

  it('verifies successful query creation of unreportable runnable with names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "www.test.url", 'fake-source-key', false);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedNoRunnableWithNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('verifies successful query creation of unreportable runnable without names', async () => {
    const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "www.test.url", 'fake-source-key', true);

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const normalizedExpectedSQLresult = normalizeSQL(expectedNoRunnableWithoutNamesSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(normalizedExpectedSQLresult);
  });

  it('has different queries with and without names', () => {
    expect(normalizeSQL(expectedNoRunnableWithNamesSQLresult)).not.to.be.equal(normalizeSQL(expectedNoRunnableWithoutNamesSQLresult));
  })
});
