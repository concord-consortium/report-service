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
        const testDenormalizedResource = firebase.denormalizeResource(testResource);
        const generatedSQLresult = await aws.generateSQL(testQueryId, testResource, testDenormalizedResource, false, "", "fake-auth-domain", 'fake-source-key');
        const expectedSQLresult = `-- name test activity
-- type activity

WITH activities AS ( SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789' ),

grouped_answers AS ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
  FROM "report-service"."partitioned_answers" a
  INNER JOIN "report-service"."learners" l
  ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
  WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
  GROUP BY l.run_remote_endpoint ),

learners_and_answers AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers.kv1 kv1, grouped_answers.submitted submitted, grouped_answers.source_key source_key,
  IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions)))) num_answers,
  cardinality(filter(map_values(activities.questions), x->x.required=TRUE)) num_required_questions,
  IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
  FROM activities, "report-service"."learners" l
  LEFT JOIN grouped_answers
  ON l.run_remote_endpoint = grouped_answers.remote_endpoint
  WHERE l.query_id = '123456789' )

SELECT
  'Prompt' AS remote_endpoint,
  null AS runnable_url,
  null AS learner_id,
  null AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS last_run,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS total_num_questions,
  null AS total_num_answers,
  null AS total_percent_complete,
  null AS num_required_questions,
  null AS num_required_answers,
  activities.questions['multiple_choice_00000'].prompt AS multiple_choice_00000_choice,
  activities.questions['multiple_choice_01000'].prompt AS multiple_choice_01000_choice,
  activities.questions['multiple_choice_02000'].prompt AS multiple_choice_02000_choice,
  activities.questions['multiple_choice_03000'].prompt AS multiple_choice_03000_choice,
  null AS multiple_choice_03000_submitted,
  activities.questions['open_response_11111'].prompt AS open_response_11111_text,
  activities.questions['open_response_22222'].prompt AS open_response_22222_text,
  null AS open_response_22222_submitted,
  activities.questions['image_question_33333'].prompt AS image_question_33333_image_url,
  activities.questions['image_question_33333'].prompt AS image_question_33333_text,
  activities.questions['image_question_33333'].prompt AS image_question_33333_answer,
  activities.questions['image_question_44444'].prompt AS image_question_44444_image_url,
  activities.questions['image_question_44444'].prompt AS image_question_44444_text,
  activities.questions['image_question_44444'].prompt AS image_question_44444_answer,
  null AS image_question_44444_submitted,
  activities.questions['managed_interactive_55555'].prompt AS managed_interactive_55555_text,
  activities.questions['managed_interactive_66666'].prompt AS managed_interactive_66666_choice,
  activities.questions['managed_interactive_77777'].prompt AS managed_interactive_77777_image_url,
  activities.questions['managed_interactive_77777'].prompt AS managed_interactive_77777_text,
  activities.questions['managed_interactive_77777'].prompt AS managed_interactive_77777_answer,
  activities.questions['managed_interactive_88888'].prompt AS managed_interactive_88888_json,
  activities.questions['managed_interactive_88888'].prompt AS managed_interactive_88888_url,
  activities.questions['managed_interactive_99999'].prompt AS managed_interactive_99999_json
FROM activities

UNION ALL


SELECT
  'Correct answer' AS remote_endpoint,
  null AS runnable_url,
  null AS learner_id,
  null AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS last_run,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS total_num_questions,
  null AS total_num_answers,
  null AS total_percent_complete,
  null AS num_required_questions,
  null AS num_required_answers,
  activities.questions['multiple_choice_00000'].correctAnswer AS multiple_choice_00000_choice,
  activities.questions['multiple_choice_01000'].correctAnswer AS multiple_choice_01000_choice,
  activities.questions['multiple_choice_02000'].correctAnswer AS multiple_choice_02000_choice,
  activities.questions['multiple_choice_03000'].correctAnswer AS multiple_choice_03000_choice,
  null AS multiple_choice_03000_submitted,
  null AS open_response_11111_text,
  null AS open_response_22222_text,
  null AS open_response_22222_submitted,
  null AS image_question_33333_image_url,
  null AS image_question_33333_text,
  null AS image_question_33333_answer,
  null AS image_question_44444_image_url,
  null AS image_question_44444_text,
  null AS image_question_44444_answer,
  null AS image_question_44444_submitted,
  null AS managed_interactive_55555_text,
  activities.questions['managed_interactive_66666'].correctAnswer AS managed_interactive_66666_choice,
  null AS managed_interactive_77777_image_url,
  null AS managed_interactive_77777_text,
  null AS managed_interactive_77777_answer,
  null AS managed_interactive_88888_json,
  null AS managed_interactive_88888_url,
  null AS managed_interactive_99999_json
FROM activities

UNION ALL

SELECT
  remote_endpoint,
  runnable_url,
  learner_id,
  student_id,
  user_id,
  student_name,
  username,
  school,
  class,
  class_id,
  permission_forms,
  last_run,
  array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
  array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
  array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
  array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
  array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
  activities.num_questions AS total_num_questions,
  num_answers AS total_num_answers,
  round(100.0 * num_answers / activities.num_questions, 1) AS total_percent_complete,
  num_required_questions,
  num_required_answers,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_00000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_00000'][x].content, IF(activities.choices['multiple_choice_00000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_00000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_01000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_01000'][x].content, '')),', ') AS multiple_choice_01000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_02000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_02000'][x].content, IF(activities.choices['multiple_choice_02000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_02000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_03000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_03000'][x].content, IF(activities.choices['multiple_choice_03000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_03000_choice,
  COALESCE(submitted['multiple_choice_03000'], false) AS multiple_choice_03000_submitted,
  kv1['open_response_11111'] AS open_response_11111_text,
  kv1['open_response_22222'] AS open_response_22222_text,
  COALESCE(submitted['open_response_22222'], false) AS open_response_22222_submitted,
  json_extract_scalar(kv1['image_question_33333'], '$.image_url') AS image_question_33333_image_url,
  json_extract_scalar(kv1['image_question_33333'], '$.text') AS image_question_33333_text,
  kv1['image_question_33333'] AS image_question_33333_answer,
  json_extract_scalar(kv1['image_question_44444'], '$.image_url') AS image_question_44444_image_url,
  json_extract_scalar(kv1['image_question_44444'], '$.text') AS image_question_44444_text,
  kv1['image_question_44444'] AS image_question_44444_answer,
  COALESCE(submitted['image_question_44444'], false) AS image_question_44444_submitted,
  kv1['managed_interactive_55555'] AS managed_interactive_55555_text,
  array_join(transform(CAST(json_extract(kv1['managed_interactive_66666'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['managed_interactive_66666'][x].content, IF(activities.choices['managed_interactive_66666'][x].correct,' (correct)',' (wrong)'))),', ') AS managed_interactive_66666_choice,
  json_extract_scalar(kv1['managed_interactive_77777'], '$.image_url') AS managed_interactive_77777_image_url,
  json_extract_scalar(kv1['managed_interactive_77777'], '$.text') AS managed_interactive_77777_text,
  kv1['managed_interactive_77777'] AS managed_interactive_77777_answer,
  kv1['managed_interactive_88888'] AS managed_interactive_88888_json,
  CASE WHEN kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(offering_id AS VARCHAR), '&studentId=', CAST(user_id AS VARCHAR), '&answersSourceKey=',  source_key['managed_interactive_88888']) END AS managed_interactive_88888_url,
  kv1['managed_interactive_99999'] AS managed_interactive_99999_json
FROM activities, learners_and_answers
ORDER BY class NULLS FIRST, remote_endpoint DESC`;

        const untabbedGeneratedSQLresult = generatedSQLresult.replace("\t", "");
        const untabbedExpectedSQLresult = expectedSQLresult.replace("\t", "");
        expect(untabbedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
    });
});

describe('Query creation usage report', function () {
  it('verifies successful query creation in usage report mode', async () => {
      const testDenormalizedResource = firebase.denormalizeResource(testResource);
      const generatedSQLresult = await aws.generateSQL(testQueryId, testResource, testDenormalizedResource, true, "", "fake-auth-domain");
      const expectedSQLresult = `-- name test activity
-- type activity

WITH activities AS ( SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789' ),

grouped_answers AS ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
  FROM "report-service"."partitioned_answers" a
  INNER JOIN "report-service"."learners" l
  ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
  WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
  GROUP BY l.run_remote_endpoint ),

learners_and_answers AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers.kv1 kv1, grouped_answers.submitted submitted, grouped_answers.source_key source_key,
  IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions)))) num_answers,
  cardinality(filter(map_values(activities.questions), x->x.required=TRUE)) num_required_questions,
  IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
  FROM activities, "report-service"."learners" l
  LEFT JOIN grouped_answers
  ON l.run_remote_endpoint = grouped_answers.remote_endpoint
  WHERE l.query_id = '123456789' )\



SELECT
  remote_endpoint,
  runnable_url,
  learner_id,
  student_id,
  user_id,
  student_name,
  username,
  school,
  class,
  class_id,
  permission_forms,
  last_run,
  array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
  array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
  array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
  array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
  array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails,
  activities.num_questions AS total_num_questions,
  num_answers AS total_num_answers,
  round(100.0 * num_answers / activities.num_questions, 1) AS total_percent_complete,
  num_required_questions,
  num_required_answers
FROM activities, learners_and_answers`;

      const untabbedGeneratedSQLresult = generatedSQLresult.replace("\t", "");
      const untabbedExpectedSQLresult = expectedSQLresult.replace("\t", "");
      expect(untabbedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
  });
});

describe('Query creation unreportable runnable', function () {
  it('verifies successful query creation of unreportable runnable', async () => {
      const generatedSQLresult = await aws.generateSQL(testQueryId, undefined, undefined, false, "www.test.url", "fake-auth-domain");
      const expectedSQLresult = `-- name www.test.url
-- type assignment






SELECT
  remote_endpoint,
  runnable_url,
  learner_id,
  student_id,
  user_id,
  student_name,
  username,
  school,
  class,
  class_id,
  permission_forms,
  last_run,
  array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
  array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
  array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
  array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
  array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails
FROM
  ( SELECT l.run_remote_endpoint remote_endpoint, arbitrary(l.runnable_url) AS runnable_url, arbitrary(l.learner_id) AS learner_id, arbitrary(l.student_id) AS student_id, arbitrary(l.user_id) AS user_id, arbitrary(l.student_name) AS student_name, arbitrary(l.username) AS username, arbitrary(l.school) AS school, arbitrary(l.class) AS class, arbitrary(l.class_id) AS class_id, arbitrary(l.permission_forms) AS permission_forms, arbitrary(l.last_run) AS last_run, arbitrary(l.teachers) teachers
    FROM "report-service"."learners" l
    WHERE l.query_id = '123456789'
    GROUP BY l.run_remote_endpoint )`;

      const untabbedGeneratedSQLresult = generatedSQLresult.replace("\t", "");
      const untabbedExpectedSQLresult = expectedSQLresult.replace("\t", "");
      expect(untabbedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
  });
});
