const AWS = require("aws-sdk");
const { v4: uuidv4 } = require('uuid');
const request = require("./request");

const PAGE_SIZE = 2000;

const escapeSingleQuote = (text) => text.replace(/'/g, "''");

const inList = (list) => `IN (${list.map(item => `'${escapeSingleQuote(item)}'`).join(", ")})`;

const convertTime = (fromCalendar) => {
  const [month, day, year, ...rest] = fromCalendar.split("/");
  return `${year}-${month}-${day}`;
};

exports.ensureWorkgroup = async (resource, email) => {
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
          Value: email
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
exports.fetchAndUploadLearnerData = async (jwt, query, learnersApiUrl, narrowLearners=false) => {
  const queryIdsPerRunnable = {};     // {[runnable_url]: queryId}
  const queryParams = {
    query,
    page_size: PAGE_SIZE,
    endpoint_only: narrowLearners
  };
  let foundAllLearners = false;
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

      if (res.json.learners.length < PAGE_SIZE && res.json.lastHitSortValue) {
        foundAllLearners = true;
      } else {
        queryParams.search_after = res.json.lastHitSortValue;
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

// Column format of:
// { name: "column name", value: "main value on each row", header: "optional first row value"}
const selectFromColumn = (column) => {
  if (column.value === column.name) {
    return column.value
  } else {
    return `${column.value} AS ${column.name}`
  }
}

const getColumnsForQuestion = (questionId, question, denormalizedResource, authDomain, sourceKey) => {
  const type = question.type;
  const isRequired = question.required;

  const columns = [];

  switch (type) {
    case "image_question":
      columns.push({name: `${questionId}_image_url`,
                    value: `json_extract_scalar(kv1['${questionId}'], '$.image_url')`,
                    header: `activities.questions['${questionId}'].prompt`});
      columns.push({name: `${questionId}_text`,
                    value: `json_extract_scalar(kv1['${questionId}'], '$.text')`});
      columns.push({name: `${questionId}_answer`,
                    value: `kv1['${questionId}']`});
      break;
    case "open_response":
      columns.push({name: `${questionId}_text`,
                    value: `kv1['${questionId}']`,
                    header: `activities.questions['${questionId}'].prompt`});
      break;
    case "multiple_choice":
      let questionHasCorrectAnswer = false;
      for (const choice in denormalizedResource.choices[questionId]) {
        if (denormalizedResource.choices[questionId][choice].correct) {
          questionHasCorrectAnswer = true;
        }
      }

      const answerScore = questionHasCorrectAnswer ? `IF(activities.choices['${questionId}'][x].correct,' (correct)',' (wrong)')` : `''`;
      const choiceIdsAsArray = `CAST(json_extract(kv1['${questionId}'],'$.choice_ids') AS ARRAY(VARCHAR))`;

      columns.push({name: `${questionId}_choice`,
                    value: `array_join(transform(${choiceIdsAsArray}, x -> CONCAT(activities.choices['${questionId}'][x].content, ${answerScore})),', ')`,
                    header: `activities.questions['${questionId}'].prompt`});
      break;
    case "iframe_interactive":
      columns.push({name: `${questionId}_json`,
                    value: `kv1['${questionId}']`});

      const modelUrl = [`CONCAT(`,
        `'${process.env.PORTAL_REPORT_URL}`,
        `?auth-domain=${encodeURIComponent(authDomain)}`,
        `&firebase-app=${process.env.FIREBASE_APP}`,
        `&sourceKey=${sourceKey}`,
        `&iframeQuestionId=${questionId}`,
        `&class=${encodeURIComponent(`${authDomain}/api/v1/classes/`)}',`,
        ` CAST(class_id AS VARCHAR), `,
        `'&offering=${encodeURIComponent(`${authDomain}/api/v1/offerings/`)}',`,
        ` CAST(offering_id AS VARCHAR), `,
        `'&studentId=',`,
        ` CAST(user_id AS VARCHAR), `,
        `'&answersSourceKey=', `,
        ` source_key['${questionId}']`,
        `)`
      ].join("")

      const conditionalModelUrl = `CASE WHEN kv1['${questionId}'] IS NULL THEN '' ELSE ${modelUrl} END`;

      columns.push({name: `${questionId}_url`,
                    value: conditionalModelUrl});
      break;
    case "managed_interactive":
    case "mw_interactive":
    default:
      columns.push({name: `${questionId}_json`,
                    value: `kv1['${questionId}']`});
      console.info(`Unknown question type: ${type}`);
      break;
  }

  if (isRequired) {
    columns.push({name: `${questionId}_submitted`,
                  value: `submitted['${questionId}']`})
  }
  return columns;
}

exports.generateSQL = (runnableInfo, usageReport, authDomain, sourceKey) => {
  const metadataColumnNames = [
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
  const metadataColumnsForGrouping = metadataColumnNames.map(md => {
    return {
      name: md,
      value: `arbitrary(l.${md})`
    }
  });
  const metadataColumns = metadataColumnNames.map(md => {
    return {
      name: md,
      value: md
    }
  });

  const teacherMetadataColumnDefinitions = [
    ["teacher_user_ids", "user_id"],
    ["teacher_names", "name"],
    ["teacher_districts", "district"],
    ["teacher_states", "state"],
    ["teacher_emails", "email"]
  ]
  const teacherMetadataColumns = teacherMetadataColumnDefinitions.map(tmd => {
    return {
      name: tmd[0],
      value: `array_join(transform(teachers, teacher -> teacher.${tmd[1]}), ',')`
    }
  });
  const assignTeacherVar = "arbitrary(l.teachers) teachers"

  const allColumns = [
    {name: "remote_endpoint",
     value: "remote_endpoint"},
    ...metadataColumns,
    ...teacherMetadataColumns,
  ];

  const groupingSelectMetadataColumns = metadataColumnsForGrouping.map(selectFromColumn).join(", ");

  const groupingSelect = `l.run_remote_endpoint remote_endpoint, ${groupingSelectMetadataColumns}, ${assignTeacherVar}`
  // The source_key map is just used to add an answersSourceKey to the interactive urls
  // It might be possible there will be some answers with different source_keys, however this will be rare
  // since most assignments are not mixed from LARA runtime and AP runtime. But we might
  // migrate some activities from LARA to the AP.
  const answerMaps = `map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key`;

  const queryIds = Object.keys(runnableInfo);

  let hasResource = false;
  const escapedUrls = [];
  const denormalizedResources = [];
  const names = [];
  const types = [];
  Object.values(runnableInfo).forEach(({runnableUrl, resource, denormalizedResource}) => {
    const itemHasResource = !!resource;
    const {url, name, type} = itemHasResource ? resource : {url: runnableUrl, name: runnableUrl, type: "assignment"};
    escapedUrls.push(url.replace(/[^a-z0-9]/g, "-"));
    names.push(name);
    types.push(type)
    denormalizedResources.push(denormalizedResource);
    hasResource = hasResource || itemHasResource;
  });

  const inQueryIds = inList(queryIds);
  const inEscapedUrls = inList(escapedUrls);

  const groupedAnswers = hasResource ? `
grouped_answers AS ( SELECT l.run_remote_endpoint remote_endpoint, ${answerMaps}
  FROM "report-service"."partitioned_answers" a
  INNER JOIN "report-service"."learners" l
  ON (l.query_id ${inQueryIds} AND l.run_remote_endpoint = a.remote_endpoint)
  WHERE a.escaped_url ${inEscapedUrls}
  GROUP BY l.run_remote_endpoint ),`
  : "";

  const learnersAndAnswers = hasResource ? `
learners_and_answers AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers.kv1 kv1, grouped_answers.submitted submitted, grouped_answers.source_key source_key,
  IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities.questions)))) num_answers
  FROM activities, "report-service"."learners" l
  LEFT JOIN grouped_answers
  ON l.run_remote_endpoint = grouped_answers.remote_endpoint
  WHERE l.query_id ${inQueryIds} )`
  : "";

  let headerRowUnion = "";
  let groupedSubSelect;
  if (hasResource) {
    const completionColumns = [
      {name: "num_questions",
       value: "activities.num_questions"},
      {name: "num_answers",
       value: "num_answers"},
      {name: "percent_complete",
       value: "round(100.0 * num_answers / activities.num_questions, 1)"}
    ]
    allColumns.push(...completionColumns);

    if (!usageReport) {
      const questionsColumns = [];
      denormalizedResources.forEach(denormalizedResource => {
        Object.keys(denormalizedResource.questions).forEach(questionId => {
          const question = denormalizedResource.questions[questionId];
          const questionColumns = getColumnsForQuestion(questionId, question, denormalizedResource, authDomain, sourceKey)
          questionsColumns.push(...questionColumns);
        });
      });
      allColumns.push(...questionsColumns);

      let headerRowSelect = allColumns.map(column => {
        const value = column.header || "null";
        return `${value} AS ${column.name}`;
      }).join(",\n  ");

      headerRowUnion = `
SELECT
  ${headerRowSelect}
FROM activities

UNION ALL
`;
    }

  } else {
    groupedSubSelect = `
  ( SELECT ${groupingSelect}
    FROM "report-service"."learners" l
    WHERE l.query_id ${inQueryIds}
    GROUP BY l.run_remote_endpoint )`;
  }

  const mainSelect = allColumns.map(selectFromColumn).join(",\n  ");

  return `-- name ${names.join(", ")}
-- type ${types.join(", ")}

${hasResource ? `WITH activities AS ( SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id ${inQueryIds}),` : ""}
${groupedAnswers}
${learnersAndAnswers}
${headerRowUnion}
SELECT
  ${mainSelect}
FROM${hasResource ? ` activities, learners_and_answers` : groupedSubSelect}`
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

/*
Generates a very wide row including all fields from the log and learner.
*/
exports.generateLearnerLogSQL = (queryIdsPerRunnable, authDomain, sourceKey) => {
  const logDb = process.env.LOG_ATHENA_DB_NAME;
  const runnableUrls = Object.keys(queryIdsPerRunnable);
  const queryIds = Object.values(queryIdsPerRunnable);
  return `
  -- name ${runnableUrls.join(", ")}
  -- type learner event log ⎯ [qids: ${queryIds.join(", ")}]
  SELECT *
  FROM "${logDb}"."logs_by_time" log
  INNER JOIN "report-service"."learners" learner
  ON
    (
      learner.query_id IN (${queryIds.map(id => `'${escapeSingleQuote(id)}'`)})
      AND
      learner.run_remote_endpoint = log.run_remote_endpoint
    )
  `;
};

/*
Generates a very wide row including all fields from the user log.
*/
exports.generateUserLogSQL = (usernames, activities, start_date, end_date) => {
  const logDb = process.env.LOG_ATHENA_DB_NAME;
  const where = [];
  if (usernames.length > 0) {
    where.push(`log.username IN (${usernames.map(u => `'${escapeSingleQuote(u)}'`).join(", ")})`)
  }
  if (activities.length > 0) {
    where.push(`log.activity IN (${activities.map(a => `'${escapeSingleQuote(a)}'`).join(", ")})`)
  }
  if (start_date) {
    where.push(`time >= '${convertTime(start_date)}'`)
  }
  if (end_date) {
    where.push(`time <= '${convertTime(end_date)}'`)
  }

  return `
  -- name ${where.join(" AND ")}
  -- type user event log
  -- usernames: ${JSON.stringify(usernames)}
  -- activities: ${JSON.stringify(activities)}
  SELECT *
  FROM "${logDb}"."logs_by_time" log
  WHERE ${where.join(" AND ")}
  `;
};

/*
Generates a smaller row of event details only, no portal info.
*/
exports.generateNarrowLogSQL = (queryIdsPerRunnable, authDomain, sourceKey) => {
  const logDb = process.env.LOG_ATHENA_DB_NAME;
  const runnableUrls = Object.keys(queryIdsPerRunnable);
  const queryIds = Object.values(queryIdsPerRunnable);

  return `
  -- name ${runnableUrls.join(", ")}
  -- type learner event log ⎯ [qids: ${queryIds.join(", ")}]
  SELECT log.*
  FROM "${logDb}"."logs_by_time" log
  INNER JOIN "report-service"."learners" learner
  ON
    (
      learner.query_id IN (${queryIds.map(id => `'${escapeSingleQuote(id)}'`)})
      AND
      learner.run_remote_endpoint = log.run_remote_endpoint
    )
  `;
};


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
