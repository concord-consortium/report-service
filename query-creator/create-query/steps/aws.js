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
  const escapedUrl = resource.url.replace(/[^a-z0-9]/g, "-");

  Object.keys(denormalizedResource.questions).forEach(questionId => {
    const type = questionId.split(/_\d+/).shift();
    switch (type) {
      case "image_question":
        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.image_url') AS ${questionId}_image_url`)
        selectColumns.push(`json_extract_scalar(kv1['${questionId}'], '$.text') AS ${questionId}_text`)
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_answer`)
        break;
      case "open_response":
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_text`)
        // TODO: only add if can be submitted  (need to check resource structure)
        selectColumns.push(`submitted['${questionId}'] AS ${questionId}_submitted`)
        break;
      case "multiple_choice":
        selectColumns.push(`activities.choices['${questionId}'][json_extract_scalar(kv1['${questionId}'], '$.choice_ids[0]')].content AS ${questionId}_choice`)
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

  return `WITH activities AS ( SELECT * FROM "report-service"."activity_structure" WHERE structure_id = '${queryId}' )

SELECT
  ${["remote_endpoint"].concat(selectColumns).join(",\n  ")}
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