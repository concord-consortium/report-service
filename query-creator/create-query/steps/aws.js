const AWS = require("aws-sdk");
const { v4: uuidv4 } = require('uuid');
const request = require("./request");

const PAGE_SIZE = 2000;

const usernameHashSalt = process.env.USERNAME_HASH_SALT || "no-username-salt-provided";
const maybeHashUsername = (hash, col, skipAs) => hash ? `to_hex(sha1(cast(('${usernameHashSalt}' || ${col}) as varbinary)))${!skipAs ? " as username" : ""}` : col

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

const convertTime = exports.convertTime = (fromCalendar) => {
  const [month, day, year, ...rest] = fromCalendar.split("/");
  const date = new Date(`${year}-${month}-${day}`);
  return Math.round(date.getTime() / 1000);
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

  // returns url to the single question view for the student answer in the portal dashboard
  const modelUrl = (answersSourceKey) => {
    return [`CONCAT(`,
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
      `'&answersSourceKey=',`,
      `${answersSourceKey}`,
      `)`
    ].join("");
  };

  // returns url when there is an answer present
  const conditionalModelUrl = (answer, answersSourceKey) => `CASE WHEN ${answer} IS NULL THEN '' ELSE ${modelUrl(answersSourceKey)} END`;

  // source key from answer, only exists if there is an answer
  const answersSourceKey = `${learnersAndAnswersTable}.source_key['${questionId}']`;

  // source key from extracted from the runnable url (selected as resource_url in query), either as answersSourceKey parameter or the host (normally activity-player.concord.org)
  const runnableUrl = `${learnersAndAnswersTable}.resource_url`
  const sourceKeyFromRunnableUrl = `COALESCE(url_extract_parameter(${runnableUrl}, 'answersSourceKey'), url_extract_host(${runnableUrl}))`;

  // source key from answer OR extracted from the runnable url with a special case for the offline AP
  const answersSourceKeyWithNoAnswerFallback = [
    `COALESCE(`,
      `${answersSourceKey},`,
      // swap offline source to AP to mirror what we do in AP#getCanonicalHostname
      `IF(${sourceKeyFromRunnableUrl} = 'activity-player-offline.concord.org',`,
        `'activity-player.concord.org',`,
        sourceKeyFromRunnableUrl,
      `)`,
    `)`
  ].join("");

  const answer = `${learnersAndAnswersTable}.kv1['${questionId}']`;

  switch (type) {
    case "image_question":
      columns.push({name: `${columnPrefix}_image_url`,
                    value: `json_extract_scalar(${answer}, '$.image_url')`,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_text`,
                    value: `json_extract_scalar(${answer}, '$.text')`,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_answer`,
                    value: answer,
                    header: promptHeader});
      break;
    case "open_response":
      columns.push({name: `${columnPrefix}_text`,
                    // When there is no answer to an open_response question the report state JSON is saved as the answer in Firebase.
                    // This detects if the answer looks like the report state JSON and if so returns an empty string to show there was
                    // no answer to the question.
                    value: `CASE WHEN starts_with(${answer}, '"{\\"mode\\":\\"report\\"') THEN '' ELSE (${answer}) END`,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_url`,
                    // note: conditionalModelUrl() is not used here as students can answer with only audio responses and in that
                    // case the answer does not exist as open response answers are only the text of the answer due to the
                    // question type being ported from the legacy LARA built in open response questions which only saved the text
                    value: modelUrl(answersSourceKeyWithNoAnswerFallback),
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
      const choiceIdsAsArray = `CAST(json_extract(${answer},'$.choice_ids') AS ARRAY(VARCHAR))`;

      columns.push({name: `${columnPrefix}_choice`,
                    value: `array_join(transform(${choiceIdsAsArray}, x -> CONCAT(${activitiesTable}.choices['${questionId}'][x].content, ${answerScore})),', ')`,
                    header: promptHeader,
                    secondHeader: `${activitiesTable}.questions['${questionId}'].correctAnswer`});
      break;
    case "iframe_interactive":
      columns.push({name: `${columnPrefix}_json`,
                    value: answer,
                    header: promptHeader});
      columns.push({name: `${columnPrefix}_url`,
                    value: conditionalModelUrl(answer, answersSourceKey),
                    header: promptHeader});
      break;
    case "managed_interactive":
    case "mw_interactive":
    default:
      columns.push({name: `${columnPrefix}_json`,
                    value: answer,
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

exports.generateNoResourceSQL = (runnableInfo, hideNames) => {
  const names = [];
  const types = [];
  const queryIds = Object.keys(runnableInfo);

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
    if (md === "student_name" && hideNames) {
      return {
        name: md,
        value: "arbitrary(l.student_id)"
      }
    }
    if (md === "username") {
      return {
        name: md,
        value: `arbitrary(${maybeHashUsername(hideNames, "l.username", true)})`
      }
    }
    return {
      name: md,
      value: md === "resource_url" ? "null" : `arbitrary(l.${md})`
    }
  });

  const groupingSelectMetadataColumns = metadataColumnsForGrouping.map(selectFromColumn).join(", ");
  const groupingSelect = `l.run_remote_endpoint remote_endpoint, ${groupingSelectMetadataColumns}, arbitrary(l.teachers) teachers`

  const teacherMetadataColumnDefinitions = [
    ["teacher_user_ids", "user_id"],
    ["teacher_names", "name"],
    ["teacher_districts", "district"],
    ["teacher_states", "state"],
    ["teacher_emails", "email"]
  ]

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

  const allColumns = [
    ...metadataColumns,
    {name: "remote_endpoint", value: "remote_endpoint"},
    ...teacherMetadataColumns
  ];

  queryIds.forEach(queryId => {
    names.push(runnableInfo[queryId].runnableUrl)
    types.push("assignment")
  })

  return `
  -- name ${names.join(", ")}
  -- type ${types.join(", ")}
  -- hideNames ${hideNames ? "true" : "false"}

  SELECT ${allColumns.map(selectFromColumn).join(",\n  ")}
  FROM
  ( SELECT ${groupingSelect}
    FROM "report-service"."learners" l
    WHERE l.query_id IN (${queryIds.map(id => `'${escapeSingleQuote(id)}'`).join(", ")})
    GROUP BY l.run_remote_endpoint )
  `
}

exports.generateSQL = (runnableInfo, usageReport, authDomain, sourceKey, hideNames) => {
  // first check if non of the runnables has a resource, if that is true return a query
  // without the runnable info
  let hasResource = false;
  const queryIds = Object.keys(runnableInfo);
  queryIds.forEach(queryId => {
    hasResource = hasResource || !!runnableInfo[queryId].resource;
  })
  if (!hasResource) {
    return exports.generateNoResourceSQL(runnableInfo, hideNames)
  }

  const names = [];
  const types = [];

  const denormalizedResources = [];

  const activitiesQueries = [];
  const groupedAnswerQueries = [];
  const learnerAndAnswerQueries = [];

  const activitiesTables = [];
  const learnersAndAnswersTables = [];

  let resourceColumns = [];

  queryIds.forEach((queryId, index) => {
    const resIndex = index + 1; // 1 based for display
    const {runnableUrl, resource, denormalizedResource} = runnableInfo[queryId];
    const itemHasResource = !!resource;
    const {url, name, type} = itemHasResource ? resource : {url: runnableUrl, name: runnableUrl, type: "assignment"};
    const escapedUrl = url.replace(/[^a-z0-9]/g, "-");
    const studentNameCol = hideNames ? "student_id as student_name" : "student_name";
    names.push(name);
    types.push(type)
    denormalizedResources.push(denormalizedResource);

    groupedAnswerQueries.push(`grouped_answers_${resIndex} AS (
      SELECT l.run_remote_endpoint remote_endpoint, ${answerMaps}
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = '${escapeSingleQuote(queryId)}' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = '${escapeSingleQuote(escapedUrl)}'
      GROUP BY l.run_remote_endpoint)`)

    learnerAndAnswerQueries.push(`learners_and_answers_${resIndex} AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, ${studentNameCol}, ${maybeHashUsername(hideNames, "username")}, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_${resIndex}.kv1 kv1, grouped_answers_${resIndex}.submitted submitted, grouped_answers_${resIndex}.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_${resIndex}.questions)))) num_answers,
      cardinality(filter(map_values(activities_${resIndex}.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_${resIndex} ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_${resIndex}
      ON l.run_remote_endpoint = grouped_answers_${resIndex}.remote_endpoint
      WHERE l.query_id = '${escapeSingleQuote(queryId)}')`)

    activitiesQueries.push(`activities_${resIndex} AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '${escapeSingleQuote(queryId)}')`)

    activitiesTables.push(`activities_${resIndex}`)
    learnersAndAnswersTables.push(`learners_and_answers_${resIndex}`)

    resourceColumns = resourceColumns.concat([
      {name: `res_${resIndex}_name`,
       value: `'${escapeSingleQuote(name)}'`},
      {name: `res_${resIndex}_offering_id`,
       value: `learners_and_answers_${resIndex}.offering_id`},
      {name: `res_${resIndex}_learner_id`,
       value: `learners_and_answers_${resIndex}.learner_id`},
      {name: `res_${resIndex}_remote_endpoint`,
       value: `learners_and_answers_${resIndex}.remote_endpoint`},
      {name: `res_${resIndex}_resource_url`,
       value: `learners_and_answers_${resIndex}.resource_url`},
       {name: `res_${resIndex}_last_run`,
       value: `learners_and_answers_${resIndex}.last_run`},
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

  const uniqueUserClassQuery = `unique_user_class AS (SELECT class_id, user_id,
      arbitrary(student_id) as student_id,
      arbitrary(${hideNames ? "student_id" : "student_name"}) as student_name,
      arbitrary(${maybeHashUsername(hideNames, "username", true)}) as username,
      arbitrary(school) as school,
      arbitrary(class) as class,
      arbitrary(permission_forms) as permission_forms,
      -- We could just select arbitrary(teachers) here and then do the transform in the main query
      array_join(transform(arbitrary(teachers), teacher -> teacher.user_id), ',') AS teacher_user_ids,
      array_join(transform(arbitrary(teachers), teacher -> teacher.name), ',') AS teacher_names,
      array_join(transform(arbitrary(teachers), teacher -> teacher.district), ',') AS teacher_districts,
      array_join(transform(arbitrary(teachers), teacher -> teacher.state), ',') AS teacher_states,
      array_join(transform(arbitrary(teachers), teacher -> teacher.email), ',') AS teacher_emails
    FROM "report-service"."learners" l
    WHERE l.query_id IN (${queryIds.map(id => `'${escapeSingleQuote(id)}'`).join(", ")})
    GROUP BY class_id, user_id)`

  // allows for the left joins of activites even if one or more are empty
  const oneRowTableForJoin = `one_row_table_for_join as (SELECT null AS empty)`

  const allColumns = [
    "student_id",
    "user_id",
    "student_name",
    "username",
    "school",
    "class",
    "class_id",
    "permission_forms",
    "teacher_user_ids",
    "teacher_names",
    "teacher_districts",
    "teacher_states",
    "teacher_emails",
  ].map(col => ({name: col, value: col}))

  allColumns.push(...resourceColumns)

  const groupedAnswers = groupedAnswerQueries.join(",\n\n")
  const learnersAndAnswers = learnerAndAnswerQueries.join(",\n\n")
  const activities =  activitiesQueries.join(",\n\n")
  const selects = [];

  const questionsColumns = [];

  if (!usageReport) {
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
      FROM one_row_table_for_join
      ${activitiesQueries.map((_, index) => `LEFT JOIN activities_${index + 1} ON 1=1`).join("\n")}
    `);

    selects.push(`
      SELECT
        ${secondaryHeaderSelect}
      FROM one_row_table_for_join
      ${activitiesQueries.map((_, index) => `LEFT JOIN activities_${index + 1} ON 1=1`).join("\n")}
    `);
  }

  selects.push(`
    SELECT
      unique_user_class.student_id,
      unique_user_class.user_id,
      unique_user_class.student_name,
      unique_user_class.username,
      unique_user_class.school,
      unique_user_class.class,
      unique_user_class.class_id,
      unique_user_class.permission_forms,
      unique_user_class.teacher_user_ids,
      unique_user_class.teacher_names,
      unique_user_class.teacher_districts,
      unique_user_class.teacher_states,
      unique_user_class.teacher_emails,
      ${resourceColumns.map(selectFromColumn).join(",\n")}${questionsColumns.length > 0 ? "," : ""}
      ${questionsColumns.map(selectFromColumn).join(",\n")}
    FROM unique_user_class
    ${activitiesTables.map(t => `LEFT JOIN ${t} ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1`).join("\n")}
    ${learnersAndAnswersTables.map(t => `LEFT JOIN ${t} ON unique_user_class.user_id = ${t}.user_id AND unique_user_class.class_id = ${t}.class_id`).join("\n")}
  `)

  return `-- name ${names.join(", ")}
  -- type ${types.join(", ")}
  -- reportType ${usageReport ? "usage" : "details"}
  -- hideNames ${hideNames ? "true" : "false"}

  WITH ${[activities, groupedAnswers, learnersAndAnswers, uniqueUserClassQuery, oneRowTableForJoin].join(",\n\n")}
  ${selects.join("\nUNION ALL\n")}
  ORDER BY class NULLS FIRST, username
`
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

const getLogCols = (hideNames, removeUsername) => {
  return ["id", "session", "username", "application", "activity", "event", "event_value", "time", "parameters", "extras", "run_remote_endpoint", "timestamp"]
    .map(col => `"log"."${col}"`)
    .filter(col => col === `"log"."username"` && removeUsername ? false : true)
    .map(col => col === `"log"."username"` ? maybeHashUsername(hideNames, `"log"."username"`) : col)
}

const getLearnerCols = (hideNames) => {
  return ["learner_id", "run_remote_endpoint", "class_id", "runnable_url", "student_id", "class", "school", "user_id", "offering_id", "permission_forms", "username", "student_name", "teachers", "last_run", "query_id"]
    .map(col => `"learner"."${col}"`)
    .map(col => col === `"learner"."username"` ? maybeHashUsername(hideNames, `"learner"."username"`) : col)
    .map(col => col === `"learner"."student_name"` && hideNames ? `"learner"."student_id" as student_name` : col)
}

/*
Generates a very wide row including all fields from the log and learner.
*/
exports.generateLearnerLogSQL = (queryIdsPerRunnable, hideNames) => {
  const logDb = process.env.LOG_ATHENA_DB_NAME;
  const runnableUrls = Object.keys(queryIdsPerRunnable);
  const queryIds = Object.values(queryIdsPerRunnable);

  const logCols = getLogCols(hideNames, true) // remove duplicate username in log columns
  const learnerCols = getLearnerCols(hideNames)

  const cols = logCols.concat(learnerCols).join(", ")

  return `
  -- name ${runnableUrls.join(", ")}
  -- type learner event log ⎯ [qids: ${queryIds.join(", ")}]
  -- reportType learner-event-log
  -- hideNames ${hideNames ? "true" : "false"}

  SELECT ${cols}
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
    where.push(`time >= ${convertTime(start_date)}`)
  }
  if (end_date) {
    where.push(`time <= ${convertTime(end_date)}`)
  }

  return `
  -- name ${where.join(" AND ")}
  -- type user event log
  -- reportType user-event-log
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
exports.generateNarrowLogSQL = (queryIdsPerRunnable, hideNames) => {
  const logDb = process.env.LOG_ATHENA_DB_NAME;
  const runnableUrls = Object.keys(queryIdsPerRunnable);
  const queryIds = Object.values(queryIdsPerRunnable);
  const logCols = getLogCols(hideNames).join(", ");

  return `
  -- name ${runnableUrls.join(", ")}
  -- type learner event log ⎯ [qids: ${queryIds.join(", ")}]
  -- reportType narrow-learner-event-log

  SELECT ${logCols}
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
