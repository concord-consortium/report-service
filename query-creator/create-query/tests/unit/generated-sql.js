exports.expectedDetailsReportWithNamesSQLresult = `
-- name test activity, test activity 2
-- type activity, activity
-- reportType details
-- hideNames false

WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

grouped_answers_1 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
      GROUP BY l.run_remote_endpoint),

grouped_answers_2 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
      GROUP BY l.run_remote_endpoint),

learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
      cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_1
      ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
      WHERE l.query_id = '123456789'),

learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
      cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_2
      ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
      WHERE l.query_id = 'ABCDEFGHI'),

unique_user_class AS (SELECT class_id, user_id,
      arbitrary(student_id) as student_id,
      arbitrary(student_name) as student_name,
      arbitrary(username) as username,
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
    WHERE l.query_id IN ('123456789', 'ABCDEFGHI')
    GROUP BY class_id, user_id),

one_row_table_for_join as (SELECT null AS empty)

      SELECT
        'Prompt' AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS res_1_name,
  null AS res_1_learner_id,
  null AS res_1_remote_endpoint,
  null AS res_1_resource_url,
  null AS res_1_last_run,
  null AS res_1_total_num_questions,
  null AS res_1_total_num_answers,
  null AS res_1_total_percent_complete,
  null AS res_1_num_required_questions,
  null AS res_1_num_required_answers,
  null AS res_2_name,
  null AS res_2_learner_id,
  null AS res_2_remote_endpoint,
  null AS res_2_resource_url,
  null AS res_2_last_run,
  null AS res_2_total_num_questions,
  null AS res_2_total_num_answers,
  null AS res_2_total_percent_complete,
  null AS res_2_num_required_questions,
  null AS res_2_num_required_answers,
  activities_1.questions['multiple_choice_00000'].prompt AS res_1_multiple_choice_00000_choice,
  activities_1.questions['multiple_choice_01000'].prompt AS res_1_multiple_choice_01000_choice,
  activities_1.questions['multiple_choice_02000'].prompt AS res_1_multiple_choice_02000_choice,
  activities_1.questions['multiple_choice_03000'].prompt AS res_1_multiple_choice_03000_choice,
  null AS res_1_multiple_choice_03000_submitted,
  activities_1.questions['open_response_11111'].prompt AS res_1_open_response_11111_text,
  activities_1.questions['open_response_11111'].prompt AS res_1_open_response_11111_url,
  activities_1.questions['open_response_22222'].prompt AS res_1_open_response_22222_text,
  activities_1.questions['open_response_22222'].prompt AS res_1_open_response_22222_url,
  null AS res_1_open_response_22222_submitted,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_image_url,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_text,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_answer,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_image_url,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_text,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_answer,
  null AS res_1_image_question_44444_submitted,
  activities_1.questions['managed_interactive_55555'].prompt AS res_1_managed_interactive_55555_text,
  activities_1.questions['managed_interactive_55555'].prompt AS res_1_managed_interactive_55555_url,
  activities_1.questions['managed_interactive_66666'].prompt AS res_1_managed_interactive_66666_choice,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_image_url,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_text,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_answer,
  activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_json,
  activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_url,
  activities_1.questions['managed_interactive_99999'].prompt AS res_1_managed_interactive_99999_json,
  activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_json,
  activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_url
      FROM one_row_table_for_join
      LEFT JOIN activities_1 ON 1=1
LEFT JOIN activities_2 ON 1=1

UNION ALL

      SELECT
        'Correct answer' AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS res_1_name,
  null AS res_1_learner_id,
  null AS res_1_remote_endpoint,
  null AS res_1_resource_url,
  null AS res_1_last_run,
  null AS res_1_total_num_questions,
  null AS res_1_total_num_answers,
  null AS res_1_total_percent_complete,
  null AS res_1_num_required_questions,
  null AS res_1_num_required_answers,
  null AS res_2_name,
  null AS res_2_learner_id,
  null AS res_2_remote_endpoint,
  null AS res_2_resource_url,
  null AS res_2_last_run,
  null AS res_2_total_num_questions,
  null AS res_2_total_num_answers,
  null AS res_2_total_percent_complete,
  null AS res_2_num_required_questions,
  null AS res_2_num_required_answers,
  activities_1.questions['multiple_choice_00000'].correctAnswer AS res_1_multiple_choice_00000_choice,
  activities_1.questions['multiple_choice_01000'].correctAnswer AS res_1_multiple_choice_01000_choice,
  activities_1.questions['multiple_choice_02000'].correctAnswer AS res_1_multiple_choice_02000_choice,
  activities_1.questions['multiple_choice_03000'].correctAnswer AS res_1_multiple_choice_03000_choice,
  null AS res_1_multiple_choice_03000_submitted,
  null AS res_1_open_response_11111_text,
  null AS res_1_open_response_11111_url,
  null AS res_1_open_response_22222_text,
  null AS res_1_open_response_22222_url,
  null AS res_1_open_response_22222_submitted,
  null AS res_1_image_question_33333_image_url,
  null AS res_1_image_question_33333_text,
  null AS res_1_image_question_33333_answer,
  null AS res_1_image_question_44444_image_url,
  null AS res_1_image_question_44444_text,
  null AS res_1_image_question_44444_answer,
  null AS res_1_image_question_44444_submitted,
  null AS res_1_managed_interactive_55555_text,
  null AS res_1_managed_interactive_55555_url,
  activities_1.questions['managed_interactive_66666'].correctAnswer AS res_1_managed_interactive_66666_choice,
  null AS res_1_managed_interactive_77777_image_url,
  null AS res_1_managed_interactive_77777_text,
  null AS res_1_managed_interactive_77777_answer,
  null AS res_1_managed_interactive_88888_json,
  null AS res_1_managed_interactive_88888_url,
  null AS res_1_managed_interactive_99999_json,
  null AS res_2_managed_interactive_88888_json,
  null AS res_2_managed_interactive_88888_url
      FROM one_row_table_for_join
      LEFT JOIN activities_1 ON 1=1
LEFT JOIN activities_2 ON 1=1

UNION ALL

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
      'test activity' AS res_1_name,
learners_and_answers_1.learner_id AS res_1_learner_id,
learners_and_answers_1.remote_endpoint AS res_1_remote_endpoint,
learners_and_answers_1.resource_url AS res_1_resource_url,
learners_and_answers_1.last_run AS res_1_last_run,
activities_1.num_questions AS res_1_total_num_questions,
learners_and_answers_1.num_answers AS res_1_total_num_answers,
round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
'test activity 2' AS res_2_name,
learners_and_answers_2.learner_id AS res_2_learner_id,
learners_and_answers_2.remote_endpoint AS res_2_remote_endpoint,
learners_and_answers_2.resource_url AS res_2_resource_url,
learners_and_answers_2.last_run AS res_2_last_run,
activities_2.num_questions AS res_2_total_num_questions,
learners_and_answers_2.num_answers AS res_2_total_num_answers,
round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
learners_and_answers_2.num_required_answers AS res_2_num_required_answers,
      array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_00000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_00000'][x].content, IF(activities_1.choices['multiple_choice_00000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_00000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_01000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_01000'][x].content, '')),', ') AS res_1_multiple_choice_01000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_02000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_02000'][x].content, IF(activities_1.choices['multiple_choice_02000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_02000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_03000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_03000'][x].content, IF(activities_1.choices['multiple_choice_03000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_03000_choice,
COALESCE(learners_and_answers_1.submitted['multiple_choice_03000'], false) AS res_1_multiple_choice_03000_submitted,
CASE WHEN starts_with(learners_and_answers_1.kv1['open_response_11111'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['open_response_11111']) END AS res_1_open_response_11111_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=open_response_11111&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['open_response_11111'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_open_response_11111_url,
CASE WHEN starts_with(learners_and_answers_1.kv1['open_response_22222'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['open_response_22222']) END AS res_1_open_response_22222_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=open_response_22222&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['open_response_22222'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_open_response_22222_url,
COALESCE(learners_and_answers_1.submitted['open_response_22222'], false) AS res_1_open_response_22222_submitted,
json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.image_url') AS res_1_image_question_33333_image_url,
json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.text') AS res_1_image_question_33333_text,
learners_and_answers_1.kv1['image_question_33333'] AS res_1_image_question_33333_answer,
json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.image_url') AS res_1_image_question_44444_image_url,
json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.text') AS res_1_image_question_44444_text,
learners_and_answers_1.kv1['image_question_44444'] AS res_1_image_question_44444_answer,
COALESCE(learners_and_answers_1.submitted['image_question_44444'], false) AS res_1_image_question_44444_submitted,
CASE WHEN starts_with(learners_and_answers_1.kv1['managed_interactive_55555'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['managed_interactive_55555']) END AS res_1_managed_interactive_55555_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_55555&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['managed_interactive_55555'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_managed_interactive_55555_url,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['managed_interactive_66666'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['managed_interactive_66666'][x].content, IF(activities_1.choices['managed_interactive_66666'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_managed_interactive_66666_choice,
json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.image_url') AS res_1_managed_interactive_77777_image_url,
json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.text') AS res_1_managed_interactive_77777_text,
learners_and_answers_1.kv1['managed_interactive_77777'] AS res_1_managed_interactive_77777_answer,
learners_and_answers_1.kv1['managed_interactive_88888'] AS res_1_managed_interactive_88888_json,
CASE WHEN learners_and_answers_1.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',learners_and_answers_1.source_key['managed_interactive_88888']) END AS res_1_managed_interactive_88888_url,
learners_and_answers_1.kv1['managed_interactive_99999'] AS res_1_managed_interactive_99999_json,
learners_and_answers_2.kv1['managed_interactive_88888'] AS res_2_managed_interactive_88888_json,
CASE WHEN learners_and_answers_2.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_2.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_2.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_2.user_id AS VARCHAR), '&answersSourceKey=',learners_and_answers_2.source_key['managed_interactive_88888']) END AS res_2_managed_interactive_88888_url
    FROM unique_user_class
    LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
    LEFT JOIN learners_and_answers_1 ON unique_user_class.user_id = learners_and_answers_1.user_id AND unique_user_class.class_id = learners_and_answers_1.class_id
LEFT JOIN learners_and_answers_2 ON unique_user_class.user_id = learners_and_answers_2.user_id AND unique_user_class.class_id = learners_and_answers_2.class_id

ORDER BY class NULLS FIRST, username
`;


exports.expectedDetailsReportHideNamesSQLresult = `
-- name test activity, test activity 2
  -- type activity, activity
  -- reportType details
  -- hideNames true

  WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

grouped_answers_1 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
      GROUP BY l.run_remote_endpoint),

grouped_answers_2 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
      GROUP BY l.run_remote_endpoint),

learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_id as student_name, to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary))) as username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
      cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_1
      ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
      WHERE l.query_id = '123456789'),

learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_id as student_name, to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary))) as username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
      cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_2
      ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
      WHERE l.query_id = 'ABCDEFGHI'),

unique_user_class AS (SELECT class_id, user_id,
      arbitrary(student_id) as student_id,
      arbitrary(student_id) as student_name,
      arbitrary(to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary)))) as username,
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
    WHERE l.query_id IN ('123456789', 'ABCDEFGHI')
    GROUP BY class_id, user_id),

one_row_table_for_join as (SELECT null AS empty)

      SELECT
        'Prompt' AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS res_1_name,
  null AS res_1_learner_id,
  null AS res_1_remote_endpoint,
  null AS res_1_resource_url,
  null AS res_1_last_run,
  null AS res_1_total_num_questions,
  null AS res_1_total_num_answers,
  null AS res_1_total_percent_complete,
  null AS res_1_num_required_questions,
  null AS res_1_num_required_answers,
  null AS res_2_name,
  null AS res_2_learner_id,
  null AS res_2_remote_endpoint,
  null AS res_2_resource_url,
  null AS res_2_last_run,
  null AS res_2_total_num_questions,
  null AS res_2_total_num_answers,
  null AS res_2_total_percent_complete,
  null AS res_2_num_required_questions,
  null AS res_2_num_required_answers,
  activities_1.questions['multiple_choice_00000'].prompt AS res_1_multiple_choice_00000_choice,
  activities_1.questions['multiple_choice_01000'].prompt AS res_1_multiple_choice_01000_choice,
  activities_1.questions['multiple_choice_02000'].prompt AS res_1_multiple_choice_02000_choice,
  activities_1.questions['multiple_choice_03000'].prompt AS res_1_multiple_choice_03000_choice,
  null AS res_1_multiple_choice_03000_submitted,
  activities_1.questions['open_response_11111'].prompt AS res_1_open_response_11111_text,
  activities_1.questions['open_response_11111'].prompt AS res_1_open_response_11111_url,
  activities_1.questions['open_response_22222'].prompt AS res_1_open_response_22222_text,
  activities_1.questions['open_response_22222'].prompt AS res_1_open_response_22222_url,
  null AS res_1_open_response_22222_submitted,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_image_url,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_text,
  activities_1.questions['image_question_33333'].prompt AS res_1_image_question_33333_answer,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_image_url,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_text,
  activities_1.questions['image_question_44444'].prompt AS res_1_image_question_44444_answer,
  null AS res_1_image_question_44444_submitted,
  activities_1.questions['managed_interactive_55555'].prompt AS res_1_managed_interactive_55555_text,
  activities_1.questions['managed_interactive_55555'].prompt AS res_1_managed_interactive_55555_url,
  activities_1.questions['managed_interactive_66666'].prompt AS res_1_managed_interactive_66666_choice,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_image_url,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_text,
  activities_1.questions['managed_interactive_77777'].prompt AS res_1_managed_interactive_77777_answer,
  activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_json,
  activities_1.questions['managed_interactive_88888'].prompt AS res_1_managed_interactive_88888_url,
  activities_1.questions['managed_interactive_99999'].prompt AS res_1_managed_interactive_99999_json,
  activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_json,
  activities_2.questions['managed_interactive_88888'].prompt AS res_2_managed_interactive_88888_url
      FROM one_row_table_for_join
      LEFT JOIN activities_1 ON 1=1
LEFT JOIN activities_2 ON 1=1

UNION ALL

      SELECT
        'Correct answer' AS student_id,
  null AS user_id,
  null AS student_name,
  null AS username,
  null AS school,
  null AS class,
  null AS class_id,
  null AS permission_forms,
  null AS teacher_user_ids,
  null AS teacher_names,
  null AS teacher_districts,
  null AS teacher_states,
  null AS teacher_emails,
  null AS res_1_name,
  null AS res_1_learner_id,
  null AS res_1_remote_endpoint,
  null AS res_1_resource_url,
  null AS res_1_last_run,
  null AS res_1_total_num_questions,
  null AS res_1_total_num_answers,
  null AS res_1_total_percent_complete,
  null AS res_1_num_required_questions,
  null AS res_1_num_required_answers,
  null AS res_2_name,
  null AS res_2_learner_id,
  null AS res_2_remote_endpoint,
  null AS res_2_resource_url,
  null AS res_2_last_run,
  null AS res_2_total_num_questions,
  null AS res_2_total_num_answers,
  null AS res_2_total_percent_complete,
  null AS res_2_num_required_questions,
  null AS res_2_num_required_answers,
  activities_1.questions['multiple_choice_00000'].correctAnswer AS res_1_multiple_choice_00000_choice,
  activities_1.questions['multiple_choice_01000'].correctAnswer AS res_1_multiple_choice_01000_choice,
  activities_1.questions['multiple_choice_02000'].correctAnswer AS res_1_multiple_choice_02000_choice,
  activities_1.questions['multiple_choice_03000'].correctAnswer AS res_1_multiple_choice_03000_choice,
  null AS res_1_multiple_choice_03000_submitted,
  null AS res_1_open_response_11111_text,
  null AS res_1_open_response_11111_url,
  null AS res_1_open_response_22222_text,
  null AS res_1_open_response_22222_url,
  null AS res_1_open_response_22222_submitted,
  null AS res_1_image_question_33333_image_url,
  null AS res_1_image_question_33333_text,
  null AS res_1_image_question_33333_answer,
  null AS res_1_image_question_44444_image_url,
  null AS res_1_image_question_44444_text,
  null AS res_1_image_question_44444_answer,
  null AS res_1_image_question_44444_submitted,
  null AS res_1_managed_interactive_55555_text,
  null AS res_1_managed_interactive_55555_url,
  activities_1.questions['managed_interactive_66666'].correctAnswer AS res_1_managed_interactive_66666_choice,
  null AS res_1_managed_interactive_77777_image_url,
  null AS res_1_managed_interactive_77777_text,
  null AS res_1_managed_interactive_77777_answer,
  null AS res_1_managed_interactive_88888_json,
  null AS res_1_managed_interactive_88888_url,
  null AS res_1_managed_interactive_99999_json,
  null AS res_2_managed_interactive_88888_json,
  null AS res_2_managed_interactive_88888_url
      FROM one_row_table_for_join
      LEFT JOIN activities_1 ON 1=1
LEFT JOIN activities_2 ON 1=1

UNION ALL

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
      'test activity' AS res_1_name,
learners_and_answers_1.learner_id AS res_1_learner_id,
learners_and_answers_1.remote_endpoint AS res_1_remote_endpoint,
learners_and_answers_1.resource_url AS res_1_resource_url,
learners_and_answers_1.last_run AS res_1_last_run,
activities_1.num_questions AS res_1_total_num_questions,
learners_and_answers_1.num_answers AS res_1_total_num_answers,
round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
'test activity 2' AS res_2_name,
learners_and_answers_2.learner_id AS res_2_learner_id,
learners_and_answers_2.remote_endpoint AS res_2_remote_endpoint,
learners_and_answers_2.resource_url AS res_2_resource_url,
learners_and_answers_2.last_run AS res_2_last_run,
activities_2.num_questions AS res_2_total_num_questions,
learners_and_answers_2.num_answers AS res_2_total_num_answers,
round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
learners_and_answers_2.num_required_answers AS res_2_num_required_answers,
      array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_00000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_00000'][x].content, IF(activities_1.choices['multiple_choice_00000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_00000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_01000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_01000'][x].content, '')),', ') AS res_1_multiple_choice_01000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_02000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_02000'][x].content, IF(activities_1.choices['multiple_choice_02000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_02000_choice,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['multiple_choice_03000'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['multiple_choice_03000'][x].content, IF(activities_1.choices['multiple_choice_03000'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_multiple_choice_03000_choice,
COALESCE(learners_and_answers_1.submitted['multiple_choice_03000'], false) AS res_1_multiple_choice_03000_submitted,
CASE WHEN starts_with(learners_and_answers_1.kv1['open_response_11111'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['open_response_11111']) END AS res_1_open_response_11111_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=open_response_11111&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['open_response_11111'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_open_response_11111_url,
CASE WHEN starts_with(learners_and_answers_1.kv1['open_response_22222'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['open_response_22222']) END AS res_1_open_response_22222_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=open_response_22222&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['open_response_22222'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_open_response_22222_url,
COALESCE(learners_and_answers_1.submitted['open_response_22222'], false) AS res_1_open_response_22222_submitted,
json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.image_url') AS res_1_image_question_33333_image_url,
json_extract_scalar(learners_and_answers_1.kv1['image_question_33333'], '$.text') AS res_1_image_question_33333_text,
learners_and_answers_1.kv1['image_question_33333'] AS res_1_image_question_33333_answer,
json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.image_url') AS res_1_image_question_44444_image_url,
json_extract_scalar(learners_and_answers_1.kv1['image_question_44444'], '$.text') AS res_1_image_question_44444_text,
learners_and_answers_1.kv1['image_question_44444'] AS res_1_image_question_44444_answer,
COALESCE(learners_and_answers_1.submitted['image_question_44444'], false) AS res_1_image_question_44444_submitted,
CASE WHEN starts_with(learners_and_answers_1.kv1['managed_interactive_55555'], '"{\\"mode\\":\\"report\\"') THEN '' ELSE (learners_and_answers_1.kv1['managed_interactive_55555']) END AS res_1_managed_interactive_55555_text,
CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_55555&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',COALESCE(learners_and_answers_1.source_key['managed_interactive_55555'],IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org','activity-player.concord.org',COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url))))) AS res_1_managed_interactive_55555_url,
array_join(transform(CAST(json_extract(learners_and_answers_1.kv1['managed_interactive_66666'],'$.choice_ids') AS ARRAY(VARCHAR)), x -> CONCAT(activities_1.choices['managed_interactive_66666'][x].content, IF(activities_1.choices['managed_interactive_66666'][x].correct,' (correct)',' (wrong)'))),', ') AS res_1_managed_interactive_66666_choice,
json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.image_url') AS res_1_managed_interactive_77777_image_url,
json_extract_scalar(learners_and_answers_1.kv1['managed_interactive_77777'], '$.text') AS res_1_managed_interactive_77777_text,
learners_and_answers_1.kv1['managed_interactive_77777'] AS res_1_managed_interactive_77777_answer,
learners_and_answers_1.kv1['managed_interactive_88888'] AS res_1_managed_interactive_88888_json,
CASE WHEN learners_and_answers_1.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=',learners_and_answers_1.source_key['managed_interactive_88888']) END AS res_1_managed_interactive_88888_url,
learners_and_answers_1.kv1['managed_interactive_99999'] AS res_1_managed_interactive_99999_json,
learners_and_answers_2.kv1['managed_interactive_88888'] AS res_2_managed_interactive_88888_json,
CASE WHEN learners_and_answers_2.kv1['managed_interactive_88888'] IS NULL THEN '' ELSE CONCAT('https://portal-report.test?auth-domain=fake-auth-domain&firebase-app=report-service-test&sourceKey=fake-source-key&iframeQuestionId=managed_interactive_88888&class=fake-auth-domain%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_2.class_id AS VARCHAR), '&offering=fake-auth-domain%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_2.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_2.user_id AS VARCHAR), '&answersSourceKey=',learners_and_answers_2.source_key['managed_interactive_88888']) END AS res_2_managed_interactive_88888_url
    FROM unique_user_class
    LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
    LEFT JOIN learners_and_answers_1 ON unique_user_class.user_id = learners_and_answers_1.user_id AND unique_user_class.class_id = learners_and_answers_1.class_id
LEFT JOIN learners_and_answers_2 ON unique_user_class.user_id = learners_and_answers_2.user_id AND unique_user_class.class_id = learners_and_answers_2.class_id

  ORDER BY class NULLS FIRST, username
`;

exports.expectedUsageReportWithNamesSQLresult = `
-- name test activity, test activity 2
-- type activity, activity
-- reportType usage
-- hideNames false

WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

grouped_answers_1 AS (
  SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
  FROM "report-service"."learners" l
  LEFT JOIN "report-service"."partitioned_answers" a
  ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
  WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
  GROUP BY l.run_remote_endpoint),

grouped_answers_2 AS (
  SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
  FROM "report-service"."learners" l
  LEFT JOIN "report-service"."partitioned_answers" a
  ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
  WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
  GROUP BY l.run_remote_endpoint),

learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
  IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
  cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
  IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
  FROM "report-service"."learners" l
  LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
  LEFT JOIN grouped_answers_1
  ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
  WHERE l.query_id = '123456789'),

learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_name, username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
  IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
  cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
  IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
  FROM "report-service"."learners" l
  LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
  LEFT JOIN grouped_answers_2
  ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
  WHERE l.query_id = 'ABCDEFGHI'),

unique_user_class AS (SELECT class_id, user_id,
  arbitrary(student_id) as student_id,
  arbitrary(student_name) as student_name,
  arbitrary(username) as username,
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
WHERE l.query_id IN ('123456789', 'ABCDEFGHI')
GROUP BY class_id, user_id),

one_row_table_for_join as (SELECT null AS empty)

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
  'test activity' AS res_1_name,
  learners_and_answers_1.learner_id AS res_1_learner_id,
  learners_and_answers_1.remote_endpoint AS res_1_remote_endpoint,
  learners_and_answers_1.resource_url AS res_1_resource_url,
  learners_and_answers_1.last_run AS res_1_last_run,
  activities_1.num_questions AS res_1_total_num_questions,
  learners_and_answers_1.num_answers AS res_1_total_num_answers,
  round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
  learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
  learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
  'test activity 2' AS res_2_name,
  learners_and_answers_2.learner_id AS res_2_learner_id,
  learners_and_answers_2.remote_endpoint AS res_2_remote_endpoint,
  learners_and_answers_2.resource_url AS res_2_resource_url,
  learners_and_answers_2.last_run AS res_2_last_run,
  activities_2.num_questions AS res_2_total_num_questions,
  learners_and_answers_2.num_answers AS res_2_total_num_answers,
  round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
  learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
  learners_and_answers_2.num_required_answers AS res_2_num_required_answers
FROM unique_user_class
LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
LEFT JOIN learners_and_answers_1 ON unique_user_class.user_id = learners_and_answers_1.user_id AND unique_user_class.class_id = learners_and_answers_1.class_id
LEFT JOIN learners_and_answers_2 ON unique_user_class.user_id = learners_and_answers_2.user_id AND unique_user_class.class_id = learners_and_answers_2.class_id

ORDER BY class NULLS FIRST, username
`;

exports.expectedUsageReportWithoutNamesSQLresult = `
-- name test activity, test activity 2
  -- type activity, activity
  -- reportType usage
  -- hideNames true

  WITH activities_1 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = '123456789'),

activities_2 AS (SELECT *, cardinality(questions) AS num_questions FROM "report-service"."activity_structure" WHERE structure_id = 'ABCDEFGHI'),

grouped_answers_1 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = '123456789' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000000'
      GROUP BY l.run_remote_endpoint),

grouped_answers_2 AS (
      SELECT l.run_remote_endpoint remote_endpoint, map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key
      FROM "report-service"."learners" l
      LEFT JOIN "report-service"."partitioned_answers" a
      ON (l.query_id = 'ABCDEFGHI' AND l.run_remote_endpoint = a.remote_endpoint)
      WHERE a.escaped_url = 'https---authoring-staging-concord-org-activities-000001'
      GROUP BY l.run_remote_endpoint),

learners_and_answers_1 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_id as student_name, to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary))) as username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_1.kv1 kv1, grouped_answers_1.submitted submitted, grouped_answers_1.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_1.questions)))) num_answers,
      cardinality(filter(map_values(activities_1.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_1
      ON l.run_remote_endpoint = grouped_answers_1.remote_endpoint
      WHERE l.query_id = '123456789'),

learners_and_answers_2 AS ( SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, student_id as student_name, to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary))) as username, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_2.kv1 kv1, grouped_answers_2.submitted submitted, grouped_answers_2.source_key source_key,
      IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1),map_keys(activities_2.questions)))) num_answers,
      cardinality(filter(map_values(activities_2.questions), x->x.required=TRUE)) num_required_questions,
      IF (submitted is null, 0, cardinality(filter(map_values(submitted), x->x=TRUE))) num_required_answers
      FROM "report-service"."learners" l
      LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with learners thus the 1=1
      LEFT JOIN grouped_answers_2
      ON l.run_remote_endpoint = grouped_answers_2.remote_endpoint
      WHERE l.query_id = 'ABCDEFGHI'),

unique_user_class AS (SELECT class_id, user_id,
      arbitrary(student_id) as student_id,
      arbitrary(student_id) as student_name,
      arbitrary(to_hex(sha1(cast(('no-username-salt-provided' || username) as varbinary)))) as username,
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
    WHERE l.query_id IN ('123456789', 'ABCDEFGHI')
    GROUP BY class_id, user_id),

one_row_table_for_join as (SELECT null AS empty)

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
      'test activity' AS res_1_name,
learners_and_answers_1.learner_id AS res_1_learner_id,
learners_and_answers_1.remote_endpoint AS res_1_remote_endpoint,
learners_and_answers_1.resource_url AS res_1_resource_url,
learners_and_answers_1.last_run AS res_1_last_run,
activities_1.num_questions AS res_1_total_num_questions,
learners_and_answers_1.num_answers AS res_1_total_num_answers,
round(100.0 * learners_and_answers_1.num_answers / activities_1.num_questions, 1) AS res_1_total_percent_complete,
learners_and_answers_1.num_required_questions AS res_1_num_required_questions,
learners_and_answers_1.num_required_answers AS res_1_num_required_answers,
'test activity 2' AS res_2_name,
learners_and_answers_2.learner_id AS res_2_learner_id,
learners_and_answers_2.remote_endpoint AS res_2_remote_endpoint,
learners_and_answers_2.resource_url AS res_2_resource_url,
learners_and_answers_2.last_run AS res_2_last_run,
activities_2.num_questions AS res_2_total_num_questions,
learners_and_answers_2.num_answers AS res_2_total_num_answers,
round(100.0 * learners_and_answers_2.num_answers / activities_2.num_questions, 1) AS res_2_total_percent_complete,
learners_and_answers_2.num_required_questions AS res_2_num_required_questions,
learners_and_answers_2.num_required_answers AS res_2_num_required_answers

    FROM unique_user_class
    LEFT JOIN activities_1 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
LEFT JOIN activities_2 ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1
    LEFT JOIN learners_and_answers_1 ON unique_user_class.user_id = learners_and_answers_1.user_id AND unique_user_class.class_id = learners_and_answers_1.class_id
LEFT JOIN learners_and_answers_2 ON unique_user_class.user_id = learners_and_answers_2.user_id AND unique_user_class.class_id = learners_and_answers_2.class_id

  ORDER BY class NULLS FIRST, username
`

exports.expectedNoRunnableWithNamesSQLresult = `
-- name http://no-url
-- type assignment
-- hideNames false

SELECT student_id,
  user_id,
  student_name,
  username,
  school,
  class,
  class_id,
  learner_id,
  resource_url,
  last_run,
  permission_forms,
  remote_endpoint,
  array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
  array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
  array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
  array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
  array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails
FROM
( SELECT l.run_remote_endpoint remote_endpoint, arbitrary(l.student_id) AS student_id, arbitrary(l.user_id) AS user_id, arbitrary(l.student_name) AS student_name, arbitrary(l.username) AS username, arbitrary(l.school) AS school, arbitrary(l.class) AS class, arbitrary(l.class_id) AS class_id, arbitrary(l.learner_id) AS learner_id, null AS resource_url, arbitrary(l.last_run) AS last_run, arbitrary(l.permission_forms) AS permission_forms, arbitrary(l.teachers) teachers
  FROM "report-service"."learners" l
  WHERE l.query_id IN ('123456789')
  GROUP BY l.run_remote_endpoint )
`;

exports.expectedNoRunnableWithoutNamesSQLresult = `
-- name http://no-url
-- type assignment
-- hideNames true

SELECT student_id,
user_id,
student_name,
username,
school,
class,
class_id,
learner_id,
resource_url,
last_run,
permission_forms,
remote_endpoint,
array_join(transform(teachers, teacher -> teacher.user_id), ',') AS teacher_user_ids,
array_join(transform(teachers, teacher -> teacher.name), ',') AS teacher_names,
array_join(transform(teachers, teacher -> teacher.district), ',') AS teacher_districts,
array_join(transform(teachers, teacher -> teacher.state), ',') AS teacher_states,
array_join(transform(teachers, teacher -> teacher.email), ',') AS teacher_emails
FROM
( SELECT l.run_remote_endpoint remote_endpoint, arbitrary(l.student_id) AS student_id, arbitrary(l.user_id) AS user_id, arbitrary(l.student_id) AS student_name, arbitrary(to_hex(sha1(cast(('no-username-salt-provided' || l.username) as varbinary)))) AS username, arbitrary(l.school) AS school, arbitrary(l.class) AS class, arbitrary(l.class_id) AS class_id, arbitrary(l.learner_id) AS learner_id, null AS resource_url, arbitrary(l.last_run) AS last_run, arbitrary(l.permission_forms) AS permission_forms, arbitrary(l.teachers) teachers
  FROM "report-service"."learners" l
  WHERE l.query_id IN ('123456789')
  GROUP BY l.run_remote_endpoint )
`

exports.expectedUserLogSQLresult = `
-- name log.username IN ('1@example.com', '2@example.com') AND log.activity IN ('activity-1', 'activity-2')
-- type user event log
-- reportType user-event-log
-- usernames: ["1@example.com","2@example.com"]
-- activities: ["activity-1","activity-2"]

SELECT *
FROM "undefined"."logs_by_time" log
WHERE log.username IN ('1@example.com', '2@example.com') AND log.activity IN ('activity-1', 'activity-2')
`

exports.expectedNarrowLearnerLogWithNamesSqlResult = `
-- name 0, 1
-- type learner event log ⎯ [qids: qid_1, qid_2]
-- reportType narrow-learner-event-log

SELECT "log"."id", "log"."session", "log"."username", "log"."application", "log"."activity", "log"."event", "log"."event_value", "log"."time", "log"."parameters", "log"."extras", "log"."run_remote_endpoint", "log"."timestamp"
FROM "undefined"."logs_by_time" log
INNER JOIN "report-service"."learners" learner
ON
  (
    learner.query_id IN ('qid_1','qid_2')
    AND
    learner.run_remote_endpoint = log.run_remote_endpoint
  )
`

exports.expectedNarrowLearnerLogWithoutNamesSqlResult = `
-- name 0, 1
-- type learner event log ⎯ [qids: qid_1, qid_2]
-- reportType narrow-learner-event-log

SELECT "log"."id", "log"."session", to_hex(sha1(cast(('no-username-salt-provided' || "log"."username") as varbinary))) as username, "log"."application", "log"."activity", "log"."event", "log"."event_value", "log"."time", "log"."parameters", "log"."extras", "log"."run_remote_endpoint", "log"."timestamp"
FROM "undefined"."logs_by_time" log
INNER JOIN "report-service"."learners" learner
ON
  (
    learner.query_id IN ('qid_1','qid_2')
    AND
    learner.run_remote_endpoint = log.run_remote_endpoint
  )
`

exports.expectedWideLearnerLogWithNameSqlResult = `
-- name qid_1, qid_2
-- type learner event log ⎯ [qids: http://example.com/runnable_1, http://example.com/runnable_2]
-- reportType learner-event-log
-- hideNames false

SELECT "log"."id", "log"."session", "log"."application", "log"."activity", "log"."event", "log"."event_value", "log"."time", "log"."parameters", "log"."extras", "log"."run_remote_endpoint", "log"."timestamp", "learner"."learner_id", "learner"."run_remote_endpoint", "learner"."class_id", "learner"."runnable_url", "learner"."student_id", "learner"."class", "learner"."school", "learner"."user_id", "learner"."offering_id", "learner"."permission_forms", "learner"."username", "learner"."student_name", "learner"."teachers", "learner"."last_run", "learner"."query_id"
FROM "undefined"."logs_by_time" log
INNER JOIN "report-service"."learners" learner
ON
  (
    learner.query_id IN ('http://example.com/runnable_1','http://example.com/runnable_2')
    AND
    learner.run_remote_endpoint = log.run_remote_endpoint
  )
`

exports.expectedWideLearnerLogWithoutNamesSqlResult = `
-- name qid_1, qid_2
-- type learner event log ⎯ [qids: http://example.com/runnable_1, http://example.com/runnable_2]
-- reportType learner-event-log
-- hideNames true

SELECT "log"."id", "log"."session", "log"."application", "log"."activity", "log"."event", "log"."event_value", "log"."time", "log"."parameters", "log"."extras", "log"."run_remote_endpoint", "log"."timestamp", "learner"."learner_id", "learner"."run_remote_endpoint", "learner"."class_id", "learner"."runnable_url", "learner"."student_id", "learner"."class", "learner"."school", "learner"."user_id", "learner"."offering_id", "learner"."permission_forms", to_hex(sha1(cast(('no-username-salt-provided' || "learner"."username") as varbinary))) as username, "learner"."student_id" as student_name, "learner"."teachers", "learner"."last_run", "learner"."query_id"
FROM "undefined"."logs_by_time" log
INNER JOIN "report-service"."learners" learner
ON
  (
    learner.query_id IN ('http://example.com/runnable_1','http://example.com/runnable_2')
    AND
    learner.run_remote_endpoint = log.run_remote_endpoint
  )
`