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
        const testResource = { url: "https://authoring.staging.concord.org/activities/000000" };
        const testDenormalizedResource =
        {
            questions: {
               multiple_choice_00000: {
                  prompt: "mc prompt"
               },
               open_response_11111: {
                  prompt: "open response prompt"
               },
               image_question_22222: {
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
        const expectedSQLresult = `WITH activities AS ( SELECT * FROM "report-service"."activity_structure" WHERE structure_id = '123456789' )

SELECT
  null as remote_endpoint,
  activities.questions['multiple_choice_00000'].prompt AS multiple_choice_00000_choice,
  activities.questions['open_response_11111'].prompt AS open_response_11111_text,
  null AS open_response_11111_submitted,
  activities.questions['image_question_22222'].prompt AS image_question_22222_image_url,
  null AS image_question_22222_text,
  null AS image_question_22222_answer
FROM activities

UNION ALL

SELECT
  remote_endpoint,
  activities.choices['multiple_choice_00000'][json_extract_scalar(kv1['multiple_choice_00000'], '$.choice_ids[0]')].content AS multiple_choice_00000_choice,
  kv1['open_response_11111'] AS open_response_11111_text,
  submitted['open_response_11111'] AS open_response_11111_submitted,
  json_extract_scalar(kv1['image_question_22222'], '$.image_url') AS image_question_22222_image_url,
  json_extract_scalar(kv1['image_question_22222'], '$.text') AS image_question_22222_text,
  kv1['image_question_22222'] AS image_question_22222_answer
FROM activities,
  ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
    FROM "report-service"."partitioned_answers" a
    INNER JOIN "report-service"."learners" l
    ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
    WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
    GROUP BY l.run_remote_endpoint )`;

        const untabbedGeneratedSQLresult = generatedSQLresult.replace("\t", "");
        const untabbedExpectedSQLresult = expectedSQLresult.replace("\t", "");
        console.log(untabbedGeneratedSQLresult);
        console.log(untabbedExpectedSQLresult);
        expect(untabbedGeneratedSQLresult).to.be.equal(untabbedExpectedSQLresult);
    });
});
