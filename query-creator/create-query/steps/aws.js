const AWS = require("aws-sdk");
const { v4: uuidv4 } = require('uuid');
const request = require("./request");

const PAGE_SIZE = 1000;

exports.ensureWorkgroup = async (user) => {
  const athena = new AWS.Athena({apiVersion: '2017-05-18'});
  const workgroupName = `${user.id} ${user.email}`.replace(/[^a-z0-9]/g, "-")

  let workgroup
  try {
    workgroup = await athena.getWorkGroup({WorkGroup: workgroupName}).promise();
  } catch (err) {
    workgroup = await athena.createWorkGroup({
      Name: workgroupName,
      Configuration: {
        // BytesScannedCutoffPerQuery: 'NUMBER_VALUE',
        // EnforceWorkGroupConfiguration: true || false,
        // PublishCloudWatchMetricsEnabled: true || false,
        // RequesterPaysEnabled: true || false,
        ResultConfiguration: {
          // EncryptionConfiguration: {
          //  EncryptionOption: SSE_S3 | SSE_KMS | CSE_KMS, // required
          //  KmsKey: 'STRING_VALUE'
          // },
          OutputLocation: `s3://${process.env.OUTPUT_BUCKET}/workgroup-output/${workgroupName}`
        }
      },
      Description: `Report service workgroup for ${user.email}`,
      Tags: [
        {
          Key: "email",
          Value: user.email
        }
      ]
    }).promise()
  }

  return workgroup.WorkGroup;
}

const uploadLearnerData = async (queryId, learners, workgroup) => {
  const uuid = uuidv4();
  const body = learners
    .map(l => JSON.stringify(l))
    .join("\n");
  const s3 = new AWS.S3({apiVersion: '2006-03-01'});
  await s3.putObject({
    Bucket: process.env.OUTPUT_BUCKET,
    Body: body,
    Key: `learners/${queryId}/${uuid}.json`
  }).promise()
  // TODO: tie the uploaded file to the workgroup
}

/**
 * Fetches all the learner details from the portal, given a jwt, query and learnersApiUrl.
 * This may take several requests to the portal, as this data is paginated.
 * Each time a set of learners is returned, the learners are sorted by runnableUrl, and are uploaded to an
 * S3 bucket `learners/{queryId}`, where queryId is unique per runnableUrl. This data may be uploaded to
 * several files in this folder.
 *
 * @returns queryIdsPerRunnable as {[runnable_url]: queryId}
 */
exports.fetchAndUploadLearnerData = async (jwt, query, learnersApiUrl, workgroup) => {
  const queryIdsPerRunnable = {};     // {[runnable_url]: queryId}
  const queryParams = {
    query,
    page_size: PAGE_SIZE,
    start_from: 0
  };
  let foundAllLearners = false;
  let totalLearnersFound = 0;
  while (!foundAllLearners) {
    const res = await request.getLearnerDataWithJwt(learnersApiUrl, queryParams, jwt);
    if (res.json.learners) {
      // sort the learners by their runnable_urls, create a queryId for each runnable, and
      // upload a set of learners for that queryId.
      // The queryId ties together the uploaded files to s3 and the Athena query
      const learnersPerRunnable = request.getLearnersPerRunnable(res.json.learners);
      for (const {runnableUrl, learners} of learnersPerRunnable) {
        // each runnable_url gets its own queryId, but because we're paginating through our learners,
        // we may have already seen this runnable_url.
        let queryId = queryIdsPerRunnable[runnableUrl];
        if (!queryId) {
          queryId = uuidv4();
          queryIdsPerRunnable[runnableUrl] = queryId;
        }
        await uploadLearnerData(queryId, learners, workgroup);
      };

      if (res.json.learners.length < PAGE_SIZE) {
        foundAllLearners = true;
      } else {
        totalLearnersFound += res.json.learners.length;
        queryParams.start_from = totalLearnersFound;
      }
    } else {
      throw new Error("Malformed response from the portal: " + JSON.stringify(res));
    }
  }
  return queryIdsPerRunnable;
}

exports.uploadDenormalizedResource = async (queryId, denormalizedResource, workgroup) => {
  const s3 = new AWS.S3({apiVersion: '2006-03-01'});
  await s3.putObject({
    Bucket: process.env.OUTPUT_BUCKET,
    Body: JSON.stringify(denormalizedResource),
    Key: `activity-structure/${queryId}/${queryId}-structure.json`
  }).promise()
  // TODO: tie the uploaded file to the workgroup
}

exports.generateSQL = (queryId, resource, denormalizedResource) => {
  const selectColumns = [];
  const selectColumnPrompts = [];
  const completionColumns = [
    "activities.num_questions",
    "cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) as num_answers",
    "round(100.0 * cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) / activities.num_questions, 1) as percent_complete"
  ];
  const escapedUrl = resource.url.replace(/[^a-z0-9]/g, "-");

  Object.keys(denormalizedResource.questions).forEach(questionId => {
    const type = questionId.split(/_\d+/).shift();
    switch (type) {
      case "image_question":
        // add question prompt, include empty column because UNION query requires identical number of fields
        selectColumnPrompts.push(`activities.questions['${questionId}'].prompt AS ${questionId}_image_url`);
        selectColumnPrompts.push(`null AS ${questionId}_text`);
        selectColumnPrompts.push(`null AS ${questionId}_answer`);

        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.image_url') AS ${questionId}_image_url`);
        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.text') AS ${questionId}_text`);
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_answer`);
        break;
      case "open_response":
        const isRequired = denormalizedResource.questions[questionId].required;

        // add question prompt, include empty column because UNION query requires identical number of fields
        selectColumnPrompts.push(`activities.questions['${questionId}'].prompt AS ${questionId}_text`);
        if (isRequired) {
          selectColumnPrompts.push(`null AS ${questionId}_submitted`);
        }

        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_text`);
        if (isRequired) {
          selectColumns.push(`submitted['${questionId}'] AS ${questionId}_submitted`);
        }
        break;
      case "multiple_choice":
        // add question prompt
        selectColumnPrompts.push(`activities.questions['${questionId}'].prompt AS ${questionId}_choice`);

        let questionHasCorrectAnswer = false;
        for (const choice in denormalizedResource.choices[questionId]) {
          if (denormalizedResource.choices[questionId][choice].correct) {
            questionHasCorrectAnswer = true;
          }
        }

        const answerScore = questionHasCorrectAnswer ? `IF(activities.choices['${questionId}'][x].correct,' (correct)',' (wrong)')` : `''`;
        const choiceIdsAsArray = `CAST(json_extract(kv1['${questionId}'],'$.choice_ids') AS ARRAY(VARCHAR))`;
        selectColumns.push(`array_join(transform(${choiceIdsAsArray}, x -> CONCAT(activities.choices['${questionId}'][x].content, ${answerScore})),', ') AS ${questionId}_choice`);
        break;
      case "managed_interactive":
      case "mw_interactive":
        // TODO: add support for custom report fields
        break;
      default:
        console.info(`Unknown question type: ${type}`);
        break;
    }
  })

  return `WITH activities AS ( SELECT *, cardinality(questions) as num_questions FROM "report-service"."activity_structure" WHERE structure_id = '${queryId}' )

SELECT
  ${["null as remote_endpoint,\n  null as num_questions,\n  null as num_answers,\n  null as percent_complete"].concat(selectColumnPrompts).join(",\n  ")}
FROM activities

UNION ALL

SELECT
  ${[
    "remote_endpoint",
    ...completionColumns,
    ...selectColumns
    ].join(",\n  ")}
FROM activities,
  ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
    FROM "report-service"."partitioned_answers" a
    INNER JOIN "report-service"."learners" l
    ON (l.query_id = '${queryId}' AND l.run_remote_endpoint = a.remote_endpoint)
    WHERE a.escaped_url = '${escapedUrl}'
    GROUP BY l.run_remote_endpoint )`
}

/*
  alternative subselect that puts the smaller table on the left, Athena recommends putting it on the right though (as done above)

  ( SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
    FROM "report-service"."learners" l
    INNER JOIN "report-service"."partitioned_answers" a
    ON (a.escaped_url = '${escapedUrl}' AND l.run_remote_endpoint = a.remote_endpoint)
    WHERE l.query_id = '${queryId}'
    GROUP BY l.run_remote_endpoint )`
*/

exports.createQuery = async (queryId, user, sql, workgroup) => {
  /*

  works but cannot find in aws UI, need to wait until hooked up to email notification

  const athena = new AWS.Athena({apiVersion: '2017-05-18'});
  const query = await athena.createNamedQuery({
    Name: `Query for ${user.email}`,
    Description: `Report service query for ${user.email}`,
    Database: "report-service",
    QueryString: sql,
    ClientRequestToken: queryId,
    WorkGroup: workgroup.Name
  }).promise()
  return query
  */

  return Promise.resolve(undefined)
}