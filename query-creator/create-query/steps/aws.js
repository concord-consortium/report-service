const AWS = require("aws-sdk");
const { v4: uuidv4 } = require('uuid');
const request = require("./request");

const PAGE_SIZE = 2000;

const metadataColumnNames = [
  "student_id",
  "user_id",
  "student_name",
  "username",
  "school",
  "class",
  "class_id",
  "learner_id",
  "resource_url",
  "last_run",
  "permission_forms",
]
const metadataColumnsForGrouping = metadataColumnNames.map(md => {
  return {
    name: md,
    value: md === "resource_url" ? "null" : `arbitrary(l.${md})`
  }
});

const teacherMetadataColumnDefinitions = [
  ["teacher_user_ids", "user_id"],
  ["teacher_names", "name"],
  ["teacher_districts", "district"],
  ["teacher_states", "state"],
  ["teacher_emails", "email"]
]

// Column format of:
// { name: "column name", value: "main value on each row", header: "optional first row value"}
const selectFromColumn = (column) => {
  if (column.value === column.name) {
    return column.value
  } else {
    return `${column.value} AS ${column.name}`
  }
}

// The source_key map is just used to add an answersSourceKey to the interactive urls
// It might be possible there will be some answers with different source_keys, however this will be rare
// since most assignments are not mixed from LARA runtime and AP runtime. But we might
// migrate some activities from LARA to the AP.
const answerMaps = `map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key`;

const escapeSingleQuote = (text) => text.replace(/'/g, "''");

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

const getColumnsForQuestion = (questionId, question, denormalizedResource, authDomain, sourceKey, activityIndex) => {
  const type = question.type;
  const isRequired = question.required;

  const columns = [];

  const activitiesTable = `activities_${activityIndex}`
  const learnersAndAnswersTable = `learners_and_answers_${activityIndex}`

  const promptHeader = `activities_${activityIndex}.questions['${questionId}'].prompt`;

  const columnPrefix = `res_${activityIndex}_${questionId}`;

  switch (type) {
    case "image_question":
      columns.push({name: `${columnPrefix}_image_url`,
                    value: `json_extract_scalar(${learnersAndAnswersTable}.kv1['${questionId}'], '$.image_url')`,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_text`,
                    value: `json_extract_scalar(${learnersAndAnswersTable}.kv1['${questionId}'], '$.text')`,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_answer`,
                    value: `${learnersAndAnswersTable}.kv1['${questionId}']`,
                    header: promptHeader});
      break;
    case "open_response":
      columns.push({name: `${columnPrefix}_text`,
                    value: `${learnersAndAnswersTable}.kv1['${questionId}']`,
                    header: promptHeader});
      break;
    case "multiple_choice":
      let questionHasCorrectAnswer = false;
      for (const choice in denormalizedResource.choices[questionId]) {
        if (denormalizedResource.choices[questionId][choice].correct) {
          questionHasCorrectAnswer = true;
        }
      }

      const answerScore = questionHasCorrectAnswer ? `IF(${activitiesTable}.choices['${questionId}'][x].correct,' (correct)',' (wrong)')` : `''`;
      const choiceIdsAsArray = `CAST(json_extract(${learnersAndAnswersTable}.kv1['${questionId}'],'$.choice_ids') AS ARRAY(VARCHAR))`;

      columns.push({name: `${columnPrefix}_choice`,
                    value: `array_join(transform(${choiceIdsAsArray}, x -> CONCAT(${activitiesTable}.choices['${questionId}'][x].content, ${answerScore})),', ')`,
                    header: promptHeader,
                    secondHeader: `${activitiesTable}.questions['${questionId}'].correctAnswer`});
      break;
    case "iframe_interactive":
      columns.push({name: `${columnPrefix}_json`,
                    value: `${learnersAndAnswersTable}.kv1['${questionId}']`,
                    header: promptHeader});

      const modelUrl = [`CONCAT(`,
        `'${process.env.PORTAL_REPORT_URL}`,
        `?auth-domain=${encodeURIComponent(authDomain)}`,
        `&firebase-app=${process.env.FIREBASE_APP}`,
        `&sourceKey=${sourceKey}`,
        `&iframeQuestionId=${questionId}`,
        `&class=${encodeURIComponent(`${authDomain}/api/v1/classes/`)}',`,
        ` CAST(${learnersAndAnswersTable}.class_id AS VARCHAR), `,
        `'&offering=${encodeURIComponent(`${authDomain}/api/v1/offerings/`)}',`,
        ` CAST(${learnersAndAnswersTable}.offering_id AS VARCHAR), `,
        `'&studentId=',`,
        ` CAST(${learnersAndAnswersTable}.user_id AS VARCHAR), `,
        `'&answersSourceKey=', `,
        ` ${learnersAndAnswersTable}.source_key['${questionId}']`,
        `)`
      ].join("")

      const conditionalModelUrl = `CASE WHEN ${learnersAndAnswersTable}.kv1['${questionId}'] IS NULL THEN '' ELSE ${modelUrl} END`;

      columns.push({name: `${columnPrefix}_url`,
                    value: conditionalModelUrl,
                    header: promptHeader});
      break;
    case "managed_interactive":
    case "mw_interactive":
    default:
      columns.push({name: `${columnPrefix}_json`,
                    value: `${learnersAndAnswersTable}.['${questionId}']`,
                    header: promptHeader});
      console.info(`Unknown question type: ${type}`);
      break;
  }

  if (isRequired) {
    columns.push({name: `${columnPrefix}_submitted`,
                  value: `COALESCE(${learnersAndAnswersTable}.submitted['${questionId}'], false)`})
  }
  return columns;
}

exports.generateSQL = (runnableInfo, usageReport, authDomain, sourceKey) => {
  let hasResource = false;
  const denormalizedResources = [];
  const names = [];
  const types = [];
  const resNames = {};

  const activitiesQueries = [];
  const groupedAnswerQueries = [];
  const learnerAndAnswerQueries = [];
  let completionColumns = [];

  const queryIds = Object.keys(runnableInfo);
  queryIds.forEach((queryId, index) => {
    const resIndex = index + 1; // 1 based for display
    const {runnableUrl, resource, denormalizedResource} = runnableInfo[queryId];
    const itemHasResource = !!resource;
    const {url, name, type} = itemHasResource ? resource : {url: runnableUrl, name: runnableUrl, type: "assignment"};
    const escapedUrl = url.replace(/[^a-z0-9]/g, "-");
    resNames[index] = name;
    names.push(name);
    types.push(type)
    denormalizedResources.push(denormalizedResource);
    hasResource = hasResource || itemHasResource;

    groupedAnswerQueries.push(`grouped_answers_${resIndex} AS (
      SELECT l.run_remote_endpoint remote_endpoint, ${answerMaps}
      FROM "report-service"."partitioned_answers" a
      INNER JOIN "report-service"."learners" l
      ON (l.query_id = '${escapeSingleQuote(queryId)}' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = '${escapeSingleQuote(escapedUrl)}'
      GROUP BY l.run_remote_endpoint)`)

    learnerAndAnswerQueries.push(`learners_and_answers_${resIndex} AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_${resIndex}.kv1 kv1, grouped_answers_${resIndex}.submitted submitted, grouped_answers_${resIndex}.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_${resIndex}.questions)))) num_answers,
      cardinality(filter(map_values(activities_${resIndex}.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM activities_${resIndex}, "report-service"."learners" l
      LEFT JOIN grouped_answers_${resIndex}
      ON l.run_remote_endpoint = grouped_answers_${resIndex}.remote_endpoint
      WHERE l.query_id = '${escapeSingleQuote(queryId)}')`)

    activitiesQueries.push(`activities_${resIndex} AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '${escapeSingleQuote(queryId)}')`)

    completionColumns = completionColumns.concat([
      {name: `res_${resIndex}_total_num_questions`,
       value: `activities_${resIndex}.num_questions`},
      {name: `res_${resIndex}_total_num_answers`,
       value: `learners_and_answers_${resIndex}.num_answers`},
      {name: `res_${resIndex}_total_percent_complete`,
       value: `round(100.0 * learners_and_answers_${resIndex}.num_answers / activities_${resIndex}.num_questions, 1)`},
      {name: `res_${resIndex}_num_required_questions`,
       value: `learners_and_answers_${resIndex}.num_required_questions`},
      {name: `res_${resIndex}_num_required_answers`,
      value: `learners_and_answers_${resIndex}.num_required_answers`}
    ])
  });

  const metadataColumns = metadataColumnNames.map(md => {
    return {
      name: md,
      value: md
    }
  });

  const teacherMetadataColumns = teacherMetadataColumnDefinitions.map(tmd => {
    return {
      name: tmd[0],
      value: `array_join(transform(teachers, teacher -> teacher.${tmd[1]}), ',')`
    }
  });
  const assignTeacherVar = "arbitrary(l.teachers) teachers"

  const allColumns = [
    ...metadataColumns,
    {name: "remote_endpoint", value: "remote_endpoint"},
    ...teacherMetadataColumns,
    {name: "res", value: "null"},
    {name: "res_name", value: "null"},
  ];

  const selects = [];
  let withPrefix = "";
  let orderByText = "";

  if (hasResource) {
    allColumns.push(...completionColumns);

    const groupedAnswers = groupedAnswerQueries.join(",\n\n")
    const learnersAndAnswers = learnerAndAnswerQueries.join(",\n\n")
    const activities =  activitiesQueries.join(",\n\n")
    withPrefix = `WITH ${[activities, groupedAnswers, learnersAndAnswers].join(",\n\n")}`

    orderByText += `\nORDER BY class NULLS FIRST, res, username`;

    if (!usageReport) {
      const questionsColumns = [];
      denormalizedResources.forEach((denormalizedResource, denormalizedResourceIndex) => {
        const activityIndex = denormalizedResourceIndex + 1;
        if (denormalizedResource) {
          Object.keys(denormalizedResource.questions).forEach((questionId) => {
            const question = denormalizedResource.questions[questionId];
            const questionColumns = getColumnsForQuestion(questionId, question, denormalizedResource, authDomain, sourceKey, activityIndex)
            questionsColumns.push(...questionColumns);
          });
        }
      });
      allColumns.push(...questionsColumns);

      let headerRowSelect = allColumns.map((column, idx) => {
        const value = idx === 0 ? `'Prompt'` : column.header || "null";
        return `${value} AS ${column.name}`;
      }).join(",\n  ");

      let secondaryHeaderSelect = allColumns.map((column, idx) => {
        const value = idx === 0 ? `'Correct answer'` : column.secondHeader || "null";
        return `${value} AS ${column.name}`;
      }).join(",\n  ");

      selects.push(`
        SELECT
          ${headerRowSelect}
        FROM ${activitiesQueries.map((_, index) => `activities_${index + 1}`).join(", ")}
      `);

      selects.push(`
        SELECT
          ${secondaryHeaderSelect}
        FROM activities_1
      `);
    }

    activitiesQueries.forEach((_, index) => {
      const resIndex = index + 1
      // filter out values from other tables
      const filteredColumns = allColumns.map(column => {
        if (column.name === "res") {
          return {name: column.name, value: `'${resIndex}'`}
        }
        if (column.name === "res_name") {
          return {name: column.name, value: `'${escapeSingleQuote(resNames[index] || "null")}'`}
        }
        const matches = column.name.match(/^res_(\d+)_/)
        if (matches) {
          if (resIndex === parseInt(matches[1], 10)) {
            return column
          } else {
            return {name: column.name, value: "null"}
          }
        } else {
          return column
        }
      })
      selects.push(`
        SELECT ${filteredColumns.map(selectFromColumn).join(",\n  ")}
        FROM activities_${resIndex}, learners_and_answers_${resIndex}
      `)
    })
  } else {
    const groupingSelectMetadataColumns = metadataColumnsForGrouping.map(selectFromColumn).join(", ");
    const groupingSelect = `l.run_remote_endpoint remote_endpoint, ${groupingSelectMetadataColumns}, ${assignTeacherVar}`

    selects.push(`
      SELECT ${allColumns.map(selectFromColumn).join(",\n  ")}
      FROM
      ( SELECT ${groupingSelect}
        FROM "report-service"."learners" l
        WHERE l.query_id IN (${queryIds.map(id => `'${escapeSingleQuote(id)}'`).join(", ")})
        GROUP BY l.run_remote_endpoint )
    `)
  }

  return `-- name ${names.join(", ")}
  -- type ${types.join(", ")}

${withPrefix}
${selects.join("\nUNION ALL\n")}
${orderByText}`
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
