const AWS = require("aws-sdk");
const { v4: uuidv4 } = require('uuid');
const request = require("./request");

const PAGE_SIZE = 1000;

exports.ensureWorkgroup = async (resource, user) => {
  const athena = new AWS.Athena({apiVersion: '2017-05-18'});
  const workgroupName = `${resource.name}-${resource.id}`;

  let workgroup
  try {
    workgroup = await athena.getWorkGroup({WorkGroup: workgroupName}).promise();
  } catch (err) {
    workgroup = await athena.createWorkGroup({
      Name: workgroupName,
      Configuration: {
        ResultConfiguration: {
          OutputLocation: `s3://${process.env.OUTPUT_BUCKET}/workgroup-output/${workgroupName}`
        }
      },
      Description: resource.description,
      Tags: [
        {
          Key: "email",
          Value: user.email
        }
      ]
    }).promise()
  }

  return workgroupName;
}

const uploadLearnerData = async (queryId, learners) => {
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
exports.fetchAndUploadLearnerData = async (jwt, query, learnersApiUrl) => {
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
        await uploadLearnerData(queryId, learners);
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

exports.uploadDenormalizedResource = async (queryId, denormalizedResource) => {
  const s3 = new AWS.S3({apiVersion: '2006-03-01'});
  await s3.putObject({
    Bucket: process.env.OUTPUT_BUCKET,
    Body: JSON.stringify(denormalizedResource),
    Key: `activity-structure/${queryId}/${queryId}-structure.json`
  }).promise()
  // TODO: tie the uploaded file to the workgroup
}

exports.generateSQL = (queryId, resource, denormalizedResource, usageReport) => {
  const selectColumns = [];
  const selectColumnPrompts = [];
  const completionColumns = [
    "activities.num_questions",
    "cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) as num_answers",
    "round(100.0 * cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) / activities.num_questions, 1) as percent_complete"
  ];
  const escapedUrl = resource.url.replace(/[^a-z0-9]/g, "-");

  !usageReport && Object.keys(denormalizedResource.questions).forEach(questionId => {
    const type = denormalizedResource.questions[questionId].type;
    const isRequired = denormalizedResource.questions[questionId].required;

    switch (type) {
      case "image_question":
        // add question prompt, include empty column because UNION query requires identical number of fields
        selectColumnPrompts.push(`activities.questions['${questionId}'].prompt AS ${questionId}_image_url`);
        selectColumnPrompts.push(`null AS ${questionId}_text`);
        selectColumnPrompts.push(`null AS ${questionId}_answer`);
        if (isRequired) {
          selectColumnPrompts.push(`null AS ${questionId}_submitted`);
        }

        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.image_url') AS ${questionId}_image_url`);
        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.text') AS ${questionId}_text`);
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_answer`);
        if (isRequired) {
          selectColumns.push(`submitted['${questionId}'] AS ${questionId}_submitted`);
        }
        break;
      case "open_response":
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
        if (isRequired) {
          selectColumnPrompts.push(`null AS ${questionId}_submitted`);
        }

        let questionHasCorrectAnswer = false;
        for (const choice in denormalizedResource.choices[questionId]) {
          if (denormalizedResource.choices[questionId][choice].correct) {
            questionHasCorrectAnswer = true;
          }
        }

        const answerScore = questionHasCorrectAnswer ? `IF(activities.choices['${questionId}'][x].correct,' (correct)',' (wrong)')` : `''`;
        const choiceIdsAsArray = `CAST(json_extract(kv1['${questionId}'],'$.choice_ids') AS ARRAY(VARCHAR))`;
        selectColumns.push(`array_join(transform(${choiceIdsAsArray}, x -> CONCAT(activities.choices['${questionId}'][x].content, ${answerScore})),', ') AS ${questionId}_choice`);
        if (isRequired) {
          selectColumns.push(`submitted['${questionId}'] AS ${questionId}_submitted`);
        }
        break;
      case "iframe_interactive":
        selectColumnPrompts.push(`null AS ${questionId}_json`);
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_json`);
        break;
      case "managed_interactive":
      case "mw_interactive":
      default:
        selectColumnPrompts.push(`null AS ${questionId}_json`);
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_json`);
        console.info(`Unknown question type: ${type}`);
        break;
    }
  })

  const metadataColumns = [
    "runnable_url",
    "learner_id",
    "student_id",
    "user_id",
    "student_name",
    "username",
    "school",
    "class",
    "class_id",
    "permission_forms",
    "last_run",
  ]
  const nullAsMetadata = metadataColumns.map(md => `  null as ${md}`).join(",\n") + ",\n"
  const assignMetadata = metadataColumns.map(md => `arbitrary(l.${md}) ${md}`).join(",")

  const teacherMetadataColumns = [
    ["teacher_user_ids", "user_id"],
    ["teacher_names", "name"],
    ["teacher_districts", "district"],
    ["teacher_states", "state"],
    ["teacher_emails", "email"]
  ]
  const teacherMetadataColumnsLabels = teacherMetadataColumns.map(tmd => tmd[0])
  const nullAsTeacherMetadata = teacherMetadataColumnsLabels.map(md => `  null as ${md}`).join(",\n") + ",\n"
  const assignTeacherMetaData = teacherMetadataColumns.map(tmd => `array_join(transform(teachers, teacher -> teacher.${tmd[1]}), ',') as ${tmd[0]}`)
  const assignTeacherVar = "arbitrary(l.teachers) teachers"

  const promptsUnion = usageReport ? "" :
`
SELECT
  ${[`null as remote_endpoint,\n${nullAsMetadata}${nullAsTeacherMetadata}  null as num_questions,\n  null as num_answers,\n  null as percent_complete`].concat(selectColumnPrompts).join(",\n  ")}
FROM activities

UNION ALL
`;

  return `-- name ${resource.name}
-- type ${resource.type}

WITH activities AS ( SELECT *, cardinality(questions) as num_questions FROM "report-service"."activity_structure" WHERE structure_id = '${queryId}' )
${promptsUnion}
SELECT
  ${[
    "remote_endpoint",
    ...metadataColumns,
    ...assignTeacherMetaData,
    ...completionColumns,
    ...selectColumns
    ].join(",\n  ")}
FROM activities,
  ( SELECT l.run_remote_endpoint remote_endpoint, ${assignMetadata}, ${assignTeacherVar}, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted
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

exports.startQueryExecution = async (sql, workgroupName) => {
  const athena = new AWS.Athena({apiVersion: '2017-05-18'});
  var params = {
    QueryString: sql,
    QueryExecutionContext: {
      Database: "report-service"
    },
    WorkGroup: workgroupName
  };
  return athena.startQueryExecution(params).promise();
}
