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
  const whereClauses = [];

  Object.keys(denormalizedResource.questions).forEach(questionId => {
    const type = questionId.split(/_\d+/).shift();
    switch (type) {
      case "image_question":
        selectColumns.push(`json_extract_scalar(answer, '$.image_url') AS ${questionId}_image_url`)
        selectColumns.push(`json_extract_scalar(answer, '$.text') AS ${questionId}_text`)
        selectColumns.push("answer")
        break;
      case "open_response":
        selectColumns.push(`kv1['${questionId}'] AS ${questionId}_text`)
        selectColumns.push(`submitted AS ${questionId}_submitted`)
        break;
      case "multiple_choice":
        selectColumns.push(`activities.choices['${questionId}'][json_extract_scalar(kv1['${questionId}'], '$.choice_ids[0]')].content AS ${questionId}_choice`)
        break;
      default:
        throw new Error(`Unknown question type: ${type}`)
    }
    whereClauses.push(`kv1['${questionId}'] IS NOT NULL`)
  })

  const remoteEndpoints = runnable.remoteEndpoints.map(remoteEndpoint => `'${remoteEndpoint}'`)

  return `WITH activities AS ( SELECT * FROM "report-service"."activity_structure" WHERE structure_id = '${queryId}' )

SELECT
  remote_endpoint,
  ${selectColumns.join(",\n  ")}
FROM activities,
  ( SELECT remote_endpoint, map_agg(question_id, answer) kv1
    FROM "report-service"."answers"
    WHERE resource_url = '${resource.url}' AND remote_endpoint IN (${remoteEndpoints.join(", ")})
    GROUP BY remote_endpoint )
WHERE
  ${whereClauses.join(" AND\n  ")}
  `
}

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