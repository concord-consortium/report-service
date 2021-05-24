'use strict';

const app = require('../../app.js');
const aws = require('../../steps/aws.js');
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
        const testRunnable = null; // isn't used yet
        const testResource = {
          url: "https://authoring.staging.concord.org/activities/000000",
          type: "activity",
          children: [
            { type: "section",
              children: [
                { type: "page",
                  children: [
                    { id: "multiple_choice_00000" },
                    { id: "open_response_11111", required: true },
                    { id: "open_response_22222", required: false },
                    { id: "image_question_33333" }
                  ]
                }
              ]
            }
          ]
        };
        const testDenormalizedResource =
        {
            questions: {
               multiple_choice_00000: {
                  prompt: "mc prompt"
               },
               open_response_11111: {
                  prompt: "open response prompt"
               },
               open_response_22222: {
                  prompt: "open response prompt 2"
               },
               image_question_33333: {
                  prompt: "image response prompt"
               },
            },
            choices: {
                multiple_choice_00000:{
                  mc_00001: {
                     "content":"a",
                     "correct":true
                  },
                  mc_00002: {
                     "content":"b",
                     "correct":false
                  },
                  mc_00003: {
                     "content":"c",
                     "correct":false
                  }
               }
            }
         };
        const generatedSQLresult = await aws.generateSQL(testQueryId, testRunnable, testResource, testDenormalizedResource);
        const expectedSQLresult = `WITH activities AS ( SELECT *, cardinality(questions) as num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789' )

SELECT
  null as remote_endpoint,
  null as num_questions,
  null as num_answers,
  null as percent_complete,
  activities.questions['multiple_choice_00000'].prompt AS multiple_choice_00000_choice,
  activities.questions['open_response_11111'].prompt AS open_response_11111_text,
  null AS open_response_11111_submitted,
  activities.questions['open_response_22222'].prompt AS open_response_22222_text,
  activities.questions['image_question_33333'].prompt AS image_question_33333_image_url,
  null AS image_question_33333_text,
  null AS image_question_33333_answer
FROM activities

UNION ALL

SELECT
  remote_endpoint,
  activities.num_questions,
  cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) as num_answers,
  round(100.0 * cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) / activities.num_questions, 1) as percent_complete,
  activities.choices['multiple_choice_00000'][json_extract_scalar(kv1['multiple_choice_00000'], '$.choice_ids[0]')].content AS multiple_choice_00000_choice,
  kv1['open_response_11111'] AS open_response_11111_text,
  submitted['open_response_11111'] AS open_response_11111_submitted,
  kv1['open_response_22222'] AS open_response_22222_text,
  json_extract_scalar(kv1['image_question_33333'], '$.image_url') AS image_question_33333_image_url,
  json_extract_scalar(kv1['image_question_33333'], '$.text') AS image_question_33333_text,
  kv1['image_question_33333'] AS image_question_33333_answer
FROM activities,
  ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
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
