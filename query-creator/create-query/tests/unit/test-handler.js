'use strict';

const app = require('../../app.js');
const aws = require('../../steps/aws.js');
const firebase = require('../../steps/firebase.js');
const chai = require('chai');
const expect = chai.expect;
var event, context;

describe('Tests index', function () {
    it('verifies successful response', async () => {
        const result = await app.lambdaHandler(event, context)

        expect(result).to.be.an('object');
        // expect(result.statusCode).to.equal(200);
        expect(result.body).to.be.an('string');

        let response = JSON.parse(result.body);

        expect(response).to.be.an('object');
        // expect(response.message).to.be.equal("create query");
        // expect(response.location).to.be.an("string");
    });
});

describe('Query creation', function () {
    it('verifies successful query creation', async () => {
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
                    { id: "open_response_11111", type: "open_response", prompt: "open response prompt 1", required: false },
                    { id: "open_response_22222", type: "open_response", prompt: "open response prompt 2", required: true },
                    { id: "image_question_33333", type: "image_question", prompt: "image response prompt 1", required: false },
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
        const testDenormalizedResource = firebase.denormalizeResource(testResource);
        const generatedSQLresult = await aws.generateSQL(testQueryId, testResource, testDenormalizedResource);
        const expectedSQLresult = `-- name test activity
-- type activity

WITH activities AS ( SELECT *, cardinality(questions) as num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789' )

SELECT
  null as remote_endpoint,
  null as runnable_url,
  null as learner_id,
  null as student_id,
  null as user_id,
  null as student_name,
  null as username,
  null as school,
  null as class,
  null as class_id,
  null as permission_forms,
  null as last_run,
  null as teacher_user_ids,
  null as teacher_names,
  null as teacher_districts,
  null as teacher_states,
  null as teacher_emails,
  null as num_questions,
  null as num_answers,
  null as percent_complete,
  activities.questions['multiple_choice_00000'].prompt AS multiple_choice_00000_choice,
  activities.questions['multiple_choice_01000'].prompt AS multiple_choice_01000_choice,
  activities.questions['multiple_choice_02000'].prompt AS multiple_choice_02000_choice,
  activities.questions['multiple_choice_03000'].prompt AS multiple_choice_03000_choice,
  null AS multiple_choice_03000_submitted,
  activities.questions['open_response_11111'].prompt AS open_response_11111_text,
  activities.questions['open_response_22222'].prompt AS open_response_22222_text,
  null AS open_response_22222_submitted,
  activities.questions['image_question_33333'].prompt AS image_question_33333_image_url,
  null AS image_question_33333_text,
  null AS image_question_33333_answer,
  activities.questions['image_question_44444'].prompt AS image_question_44444_image_url,
  null AS image_question_44444_text,
  null AS image_question_44444_answer,
  null AS image_question_44444_submitted,
  activities.questions['managed_interactive_55555'].prompt AS managed_interactive_55555_text,
  activities.questions['managed_interactive_66666'].prompt AS managed_interactive_66666_choice,
  activities.questions['managed_interactive_77777'].prompt AS managed_interactive_77777_image_url,
  null AS managed_interactive_77777_text,
  null AS managed_interactive_77777_answer,
  null AS managed_interactive_88888_json,
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
  array_join(transform(teachers, teacher -> teacher.user_id), ',') as teacher_user_ids,
  array_join(transform(teachers, teacher -> teacher.name), ',') as teacher_names,
  array_join(transform(teachers, teacher -> teacher.district), ',') as teacher_districts,
  array_join(transform(teachers, teacher -> teacher.state), ',') as teacher_states,
  array_join(transform(teachers, teacher -> teacher.email), ',') as teacher_emails,
  activities.num_questions,
  cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) as num_answers,
  round(100.0 * cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) / activities.num_questions, 1) as percent_complete,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_00000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_00000'][x].content, IF(activities.choices['multiple_choice_00000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_00000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_01000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_01000'][x].content, '')),', ') AS multiple_choice_01000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_02000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_02000'][x].content, IF(activities.choices['multiple_choice_02000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_02000_choice,
  array_join(transform(CAST(json_extract(kv1['multiple_choice_03000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['multiple_choice_03000'][x].content, IF(activities.choices['multiple_choice_03000'][x].correct,' (correct)',' (wrong)'))),', ') AS multiple_choice_03000_choice,
  submitted['multiple_choice_03000'] AS multiple_choice_03000_submitted,
  kv1['open_response_11111'] AS open_response_11111_text,
  kv1['open_response_22222'] AS open_response_22222_text,
  submitted['open_response_22222'] AS open_response_22222_submitted,
  json_extract_scalar(kv1['image_question_33333'], '$.image_url') AS image_question_33333_image_url,
  json_extract_scalar(kv1['image_question_33333'], '$.text') AS image_question_33333_text,
  kv1['image_question_33333'] AS image_question_33333_answer,
  json_extract_scalar(kv1['image_question_44444'], '$.image_url') AS image_question_44444_image_url,
  json_extract_scalar(kv1['image_question_44444'], '$.text') AS image_question_44444_text,
  kv1['image_question_44444'] AS image_question_44444_answer,
  submitted['image_question_44444'] AS image_question_44444_submitted,
  kv1['managed_interactive_55555'] AS managed_interactive_55555_text,
  array_join(transform(CAST(json_extract(kv1['managed_interactive_66666'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities.choices['managed_interactive_66666'][x].content, IF(activities.choices['managed_interactive_66666'][x].correct,' (correct)',' (wrong)'))),', ') AS managed_interactive_66666_choice,
  json_extract_scalar(kv1['managed_interactive_77777'], '$.image_url') AS managed_interactive_77777_image_url,
  json_extract_scalar(kv1['managed_interactive_77777'], '$.text') AS managed_interactive_77777_text,
  kv1['managed_interactive_77777'] AS managed_interactive_77777_answer,
  kv1['managed_interactive_88888'] AS managed_interactive_88888_json,
  kv1['managed_interactive_99999'] AS managed_interactive_99999_json
FROM activities,
  ( SELECT l.run_remote_endpoint remote_endpoint, arbitrary(l.runnable_url) runnable_url,arbitrary(l.learner_id) learner_id,arbitrary(l.student_id) student_id,arbitrary(l.user_id) user_id,arbitrary(l.student_name) student_name,arbitrary(l.username) username,arbitrary(l.school) school,arbitrary(l.class) class,arbitrary(l.class_id) class_id,arbitrary(l.permission_forms) permission_forms,arbitrary(l.last_run) last_run, arbitrary(l.teachers) teachers, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
    FROM "report-service"."partitioned_answers" a
    INNER JOIN "report-service"."learners" l
    ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
    WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
    GROUP BY l.run_remote_endpoint )`;

        const untabbedGeneratedSQLresult = generatedSQLresult.replace("\t", "");
        const untabbedExpectedSQLresult = expectedSQLresult.replace("\t", "");
        expect(untabbedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
    });
});
