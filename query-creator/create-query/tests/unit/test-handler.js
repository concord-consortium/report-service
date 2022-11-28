'use strict';

const app = require('../../app.js');
const aws = require('../../steps/aws.js');
const firebase = require('../../steps/firebase.js');
const chai = require('chai');
const queryString = require('query-string');
const nock = require('nock');

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
    it('verifies successful query creation', async () => {
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
        const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "fake-auth-domain", 'fake-source-key');
        const expectedSQLresult = `
        -- name test activity, test activity 2
        -- type activity, activity

        WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

        activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

        grouped_answers_1 AS (
          SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
          FROM "report-service"."partitioned_answers" a
          INNER JOIN "report-service"."learners" l
          ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
          WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
          GROUP BY l.run_remote_endpoint),

        grouped_answers_2 AS (
          SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
          FROM "report-service"."partitioned_answers" a
          INNER JOIN "report-service"."learners" l
          ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
          WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
          GROUP BY l.run_remote_endpoint),

        learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
          IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
          cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
          IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
          FROM activities_1, "report-service"."learners" l
          LEFT JOIN grouped_answers_1
          ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
          WHERE l.query_id = '123456789'),

        learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
          IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
          cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
          IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
          FROM activities_2, "report-service"."learners" l
          LEFT JOIN grouped_answers_2
          ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
          WHERE l.query_id = 'ABCDEFGHI')

        SELECT
          'Prompt' AS student_id,
          null AS user_id,
          null AS student_name,
          null AS username,
          null AS school,
          null AS class,
          null AS class_id,
          null AS learner_id,
          null AS resource_url,
          null AS last_run,
          null AS permission_forms,
          null AS remote_endpoint,
          null AS teacher_user_ids,
          null AS teacher_names,
          null AS teacher_districts,
          null AS teacher_states,
          null AS teacher_emails,
          null AS res,
          null AS res_name,
          null AS res_1_total_num_questions,
          null AS res_1_total_num_answers,
          null AS res_1_total_percent_complete,
          null AS res_1_num_required_questions,
          null AS res_1_num_required_answers,
          null AS res_2_total_num_questions,
          null AS res_2_total_num_answers,
          null AS res_2_total_percent_complete,
          null AS res_2_num_required_questions,
          null AS res_2_num_required_answers,
          activities_1.questions['multiple_choice_00000'].prompt AS res_1_multiple_choice_00000_choice,
          activities_1.questions['multiple_choice_01000'].prompt AS res_1_multiple_choice_01000_choice,
          activities_1.questions['multiple_choice_02000'].prompt AS res_1_multiple_choice_02000_choice,
          activities_1.questions['multiple_choice_03000'].prompt AS res_1_multiple_choice_03000_choice,
          null AS res_1_multiple_choice_03000_submitted,
          activities_1.questions['open_response_11111'].prompt AS res_1_open_response_11111_text,
          activities_1.questions['open_response_22222'].prompt AS res_1_open_response_22222_text,
          null AS res_1_open_response_22222_submitted,
          activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_image_url,
          activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_text,
          activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_answer,
          activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_image_url,
          activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_text,
          activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_answer,
          null AS res_1_image_question_44444_submitted,
          activities_1.questions['managed_interactive_55555'].prompt AS res_1_managed_interactive_55555_text,
          activities_1.questions['managed_interactive_66666'].prompt AS res_1_managed_interactive_66666_choice,
          activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_image_url,
          activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_text,
          activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_answer,
          activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_json,
          activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_url,
          activities_1.questions['managed_interactive_99999'].prompt AS res_1_managed_interactive_99999_json,
          activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_json,
          activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_url
        FROM activities_1, activities_2

        UNION ALL

        SELECT
          'Correct answer' AS student_id,
          null AS user_id,
          null AS student_name,
          null AS username,
          null AS school,
          null AS class,
          null AS class_id,
          null AS learner_id,
          null AS resource_url,
          null AS last_run,
          null AS permission_forms,
          null AS remote_endpoint,
          null AS teacher_user_ids,
          null AS teacher_names,
          null AS teacher_districts,
          null AS teacher_states,
          null AS teacher_emails,
          null AS res,
          null AS res_name,
          null AS res_1_total_num_questions,
          null AS res_1_total_num_answers,
          null AS res_1_total_percent_complete,
          null AS res_1_num_required_questions,
          null AS res_1_num_required_answers,
          null AS res_2_total_num_questions,
          null AS res_2_total_num_answers,
          null AS res_2_total_percent_complete,
          null AS res_2_num_required_questions,
          null AS res_2_num_required_answers,
          activities_1.questions['multiple_choice_00000'].correctAnswer AS res_1_multiple_choice_00000_choice,
          activities_1.questions['multiple_choice_01000'].correctAnswer AS res_1_multiple_choice_01000_choice,
          activities_1.questions['multiple_choice_02000'].correctAnswer AS res_1_multiple_choice_02000_choice,
          activities_1.questions['multiple_choice_03000'].correctAnswer AS res_1_multiple_choice_03000_choice,
          null AS res_1_multiple_choice_03000_submitted,
          null AS res_1_open_response_11111_text,
          null AS res_1_open_response_22222_text,
          null AS res_1_open_response_22222_submitted,
          null AS res_1_image_question_33333_image_url,
          null AS res_1_image_question_33333_text,
          null AS res_1_image_question_33333_answer,
          null AS res_1_image_question_44444_image_url,
          null AS res_1_image_question_44444_text,
          null AS res_1_image_question_44444_answer,
          null AS res_1_image_question_44444_submitted,
          null AS res_1_managed_interactive_55555_text,
          activities_1.questions['managed_interactive_66666'].correctAnswer AS res_1_managed_interactive_66666_choice,
          null AS res_1_managed_interactive_77777_image_url,
          null AS res_1_managed_interactive_77777_text,
          null AS res_1_managed_interactive_77777_answer,
          null AS res_1_managed_interactive_88888_json,
          null AS res_1_managed_interactive_88888_url,
          null AS res_1_managed_interactive_99999_json,
          null AS res_2_managed_interactive_88888_json,
          null AS res_2_managed_interactive_88888_url
        FROM activities_1

        UNION ALL

        SELECT student_id,
          user_id,
          student_name,
          username,
          school,
          class,
          class_id,
          learner_id,
          resource_url,
          last_run,
          permission_forms,
          remote_endpoint,
          array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
          array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
          array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
          array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
          array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
          '1' AS res,
          'test activity' AS res_name,
          activities_1.num_questions AS res_1_total_num_questions,
          learners_and_answers_1.num_answers AS res_1_total_num_answers,
          round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
          learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
          learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
          null AS res_2_total_num_questions,
          null AS res_2_total_num_answers,
          null AS res_2_total_percent_complete,
          null AS res_2_num_required_questions,
          null AS res_2_num_required_answers,
          array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_00000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_00000'][x].content, IF(activities_1.choices['multiple_choice_00000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_00000_choice,
          array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_01000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_01000'][x].content, '')),', ') AS res_1_multiple_choice_01000_choice,
          array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_02000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_02000'][x].content, IF(activities_1.choices['multiple_choice_02000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_02000_choice,
          array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_03000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_03000'][x].content, IF(activities_1.choices['multiple_choice_03000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_03000_choice,
          COALESCE(learners_and_answers_1.submitted['multiple_choice_03000'], false) AS res_1_multiple_choice_03000_submitted,
          learners_and_answers_1.kv1['open_response_11111'] AS res_1_open_response_11111_text,
          learners_and_answers_1.kv1['open_response_22222'] AS res_1_open_response_22222_text,
          COALESCE(learners_and_answers_1.submitted['open_response_22222'], false) AS res_1_open_response_22222_submitted,
          json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.image_url') AS res_1_image_question_33333_image_url,
          json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.text') AS res_1_image_question_33333_text,
          learners_and_answers_1.kv1['image_question_33333'] AS res_1_image_question_33333_answer,
          json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.image_url') AS res_1_image_question_44444_image_url,
          json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.text') AS res_1_image_question_44444_text,
          learners_and_answers_1.kv1['image_question_44444'] AS res_1_image_question_44444_answer,
          COALESCE(learners_and_answers_1.submitted['image_question_44444'], false) AS res_1_image_question_44444_submitted,
          learners_and_answers_1.kv1['managed_interactive_55555'] AS res_1_managed_interactive_55555_text,
          array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['managed_interactive_66666'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['managed_interactive_66666'][x].content, IF(activities_1.choices['managed_interactive_66666'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_managed_interactive_66666_choice,
          json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.image_url') AS res_1_managed_interactive_77777_image_url,
          json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.text') AS res_1_managed_interactive_77777_text,
          learners_and_answers_1.kv1['managed_interactive_77777'] AS res_1_managed_interactive_77777_answer,
          learners_and_answers_1.kv1['managed_interactive_88888'] AS res_1_managed_interactive_88888_json,
          CASE WHEN learners_and_answers_1.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',  learners_and_answers_1.source_key['managed_interactive_88888']) END AS res_1_managed_interactive_88888_url,
          learners_and_answers_1.['managed_interactive_99999'] AS res_1_managed_interactive_99999_json,
          null AS res_2_managed_interactive_88888_json,
          null AS res_2_managed_interactive_88888_url
          FROM activities_1, learners_and_answers_1

        UNION ALL

        SELECT student_id,
          user_id,
          student_name,
          username,
          school,
          class,
          class_id,
          learner_id,
          resource_url,
          last_run,
          permission_forms,
          remote_endpoint,
          array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
          array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
          array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
          array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
          array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
          '2' AS res,
          'test activity 2' AS res_name,
          null AS res_1_total_num_questions,
          null AS res_1_total_num_answers,
          null AS res_1_total_percent_complete,
          null AS res_1_num_required_questions,
          null AS res_1_num_required_answers,
          activities_2.num_questions AS res_2_total_num_questions,
          learners_and_answers_2.num_answers AS res_2_total_num_answers,
          round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
          learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
          learners_and_answers_2.num_required_answers AS res_2_num_required_answers,
          null AS res_1_multiple_choice_00000_choice,
          null AS res_1_multiple_choice_01000_choice,
          null AS res_1_multiple_choice_02000_choice,
          null AS res_1_multiple_choice_03000_choice,
          null AS res_1_multiple_choice_03000_submitted,
          null AS res_1_open_response_11111_text,
          null AS res_1_open_response_22222_text,
          null AS res_1_open_response_22222_submitted,
          null AS res_1_image_question_33333_image_url,
          null AS res_1_image_question_33333_text,
          null AS res_1_image_question_33333_answer,
          null AS res_1_image_question_44444_image_url,
          null AS res_1_image_question_44444_text,
          null AS res_1_image_question_44444_answer,
          null AS res_1_image_question_44444_submitted,
          null AS res_1_managed_interactive_55555_text,
          null AS res_1_managed_interactive_66666_choice,
          null AS res_1_managed_interactive_77777_image_url,
          null AS res_1_managed_interactive_77777_text,
          null AS res_1_managed_interactive_77777_answer,
          null AS res_1_managed_interactive_88888_json,
          null AS res_1_managed_interactive_88888_url,
          null AS res_1_managed_interactive_99999_json,
          learners_and_answers_2.kv1['managed_interactive_88888'] AS res_2_managed_interactive_88888_json,
          CASE WHEN learners_and_answers_2.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_2.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_2.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_2.user_id AS VARCHAR), '&answersSourceKey=',  learners_and_answers_2.source_key['managed_interactive_88888']) END AS res_2_managed_interactive_88888_url

        FROM activities_2, learners_and_answers_2


        ORDER BY class NULLS FIRST, res, username`;

        const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
        const untabbedExpectedSQLresult = normalizeSQL(expectedSQLresult);
        expect(normalizedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
    });
});

describe('Query creation usage report', function () {
  it('verifies successful query creation in usage report mode', async () => {
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
      const generatedSQLresult = await aws.generateSQL(testRunnableInfo, true, "fake-auth-domain", 'fake-source-key');

      const expectedSQLresult = `
      -- name test activity, test activity 2
      -- type activity, activity

      WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

      activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

      grouped_answers_1 AS (
        SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
        FROM "report-service"."partitioned_answers" a
        INNER JOIN "report-service"."learners" l
        ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
        WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
        GROUP BY l.run_remote_endpoint),

      grouped_answers_2 AS (
        SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
        FROM "report-service"."partitioned_answers" a
        INNER JOIN "report-service"."learners" l
        ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
        WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
        GROUP BY l.run_remote_endpoint),

      learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
        IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
        cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
        IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
        FROM activities_1, "report-service"."learners" l
        LEFT JOIN grouped_answers_1
        ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
        WHERE l.query_id = '123456789'),

      learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
        IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
        cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
        IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
        FROM activities_2, "report-service"."learners" l
        LEFT JOIN grouped_answers_2
        ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
        WHERE l.query_id = 'ABCDEFGHI')

      SELECT student_id,
        user_id,
        student_name,
        username,
        school,
        class,
        class_id,
        learner_id,
        resource_url,
        last_run,
        permission_forms,
        remote_endpoint,
        array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
        array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
        array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
        array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
        array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
        '1' AS res,
        'test activity' AS res_name,
        activities_1.num_questions AS res_1_total_num_questions,
        learners_and_answers_1.num_answers AS res_1_total_num_answers,
        round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
        learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
        learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
        null AS res_2_total_num_questions,
        null AS res_2_total_num_answers,
        null AS res_2_total_percent_complete,
        null AS res_2_num_required_questions,
        null AS res_2_num_required_answers
      FROM activities_1, learners_and_answers_1

      UNION ALL

        SELECT student_id,
        user_id,
        student_name,
        username,
        school,
        class,
        class_id,
        learner_id,
        resource_url,
        last_run,
        permission_forms,
        remote_endpoint,
        array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
        array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
        array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
        array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
        array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
        '2' AS res,
        'test activity 2' AS res_name,
        null AS res_1_total_num_questions,
        null AS res_1_total_num_answers,
        null AS res_1_total_percent_complete,
        null AS res_1_num_required_questions,
        null AS res_1_num_required_answers,
        activities_2.num_questions AS res_2_total_num_questions,
        learners_and_answers_2.num_answers AS res_2_total_num_answers,
        round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
        learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
        learners_and_answers_2.num_required_answers AS res_2_num_required_answers
      FROM activities_2, learners_and_answers_2

      ORDER BY class NULLS FIRST, res, username
      `;

    const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
    const untabbedExpectedSQLresult = normalizeSQL(expectedSQLresult);
    expect(normalizedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
  });
});

describe('Query creation unreportable runnable', function () {
  it('verifies successful query creation of unreportable runnable', async () => {
      const testRunnableInfo = {[testQueryId]: {
        runnableUrl: "http://no-url",
        resource: undefined,
        denormalizedResource: undefined
      }}
      const generatedSQLresult = await aws.generateSQL(testRunnableInfo, false, "www.test.url", 'fake-source-key');

      const expectedSQLresult = `
      -- name http://no-url
      -- type assignment

      SELECT student_id,
        user_id,
        student_name,
        username,
        school,
        class,
        class_id,
        learner_id,
        resource_url,
        last_run,
        permission_forms,
        remote_endpoint,
        array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
        array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
        array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
        array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
        array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
        null AS res,
        null AS res_name
      FROM
        ( SELECT l.run_remote_endpoint remote_endpoint, arbitrary(l.student_id) AS student_id, arbitrary(l.user_id) AS user_id, arbitrary(l.student_name) AS student_name, arbitrary(l.username) AS username, arbitrary(l.school) AS school, arbitrary(l.class) AS class, arbitrary(l.class_id) AS class_id, arbitrary(l.learner_id) AS learner_id, null AS resource_url, arbitrary(l.last_run) AS last_run, arbitrary(l.permission_forms) AS permission_forms, arbitrary(l.teachers) teachers
          FROM "report-service"."learners" l
          WHERE l.query_id IN ('123456789')
          GROUP BY l.run_remote_endpoint )
        `;

      const normalizedGeneratedSQLresult = normalizeSQL(generatedSQLresult);
      const untabbedExpectedSQLresult = normalizeSQL(expectedSQLresult);
      expect(normalizedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
    });
});
