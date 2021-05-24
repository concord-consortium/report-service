const AWS = require("aws-sdk");

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

exports.uploadLearnerData = async (queryId, learners, workgroup) => {
  const body = learners
    .map(l => JSON.stringify(l))
    .join("\n");
  const s3 = new AWS.S3({apiVersion: '2006-03-01'});
  await s3.putObject({
    Bucket: process.env.OUTPUT_BUCKET,
    Body: body,
    Key: `learners/${queryId}/${queryId}.json`
  }).promise()
  // TODO: tie the uploaded file to the workgroup
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

exports.generateSQL = (queryId, runnable, resource, denormalizedResource) => {
  const selectColumns = [];
  const selectColumnPrompts = [];
  const completionColumns = [
    "activities.num_questions",
    "cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) as num_answers",
    "round(100.0 * cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions))) / activities.num_questions, 1) as percent_complete"
  ];
  const escapedUrl = resource.url.replace(/[^a-z0-9]/g, "-");

  const questionIsRequired = (resourceObj, qId) => {
    let isRequired = false;
    if (resourceObj.type === "sequence") {
      resourceObj.children.forEach((activity) => activity.children.forEach((section) => section.children.forEach((page) => page.children.forEach((question) => {
        if (question.id === qId && question.required) {
          isRequired = true;
        }
      }))));
    } else if (resourceObj.type === "activity") {
      resourceObj.children.forEach((section) => section.children.forEach((page) => page.children.forEach((question) => {
        if (question.id === qId && question.required) {
          isRequired = true;
        }
      })));
    }
    return isRequired;
  }

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
        let isRequired = questionIsRequired(resource, questionId);

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
        const questionHasCorrectAnswer = `cardinality(map_filter(activities.choices['${questionId}'], (k, v) -> v.correct)) > 0`;
        const answerScore = `IF(${questionHasCorrectAnswer}, IF(activities.choices['${questionId}'][x].correct,' (correct)',' (wrong)'), '')`;
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