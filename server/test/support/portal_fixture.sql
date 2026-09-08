DROP TABLE IF EXISTS users;
CREATE TABLE users (id INT PRIMARY KEY, login VARCHAR(255), first_name VARCHAR(255), last_name VARCHAR(255), email VARCHAR(255), primary_account_id INT);
DROP TABLE IF EXISTS portal_districts;
CREATE TABLE portal_districts (id INT PRIMARY KEY, name VARCHAR(255), state VARCHAR(2));
DROP TABLE IF EXISTS portal_schools;
CREATE TABLE portal_schools (id INT PRIMARY KEY, name VARCHAR(255), district_id INT, state VARCHAR(80), country_id INT);
DROP TABLE IF EXISTS portal_school_memberships;
CREATE TABLE portal_school_memberships (id INT PRIMARY KEY, member_id INT, member_type VARCHAR(255), school_id INT, INDEX member_type_id_index (member_type, member_id));
DROP TABLE IF EXISTS portal_teachers;
CREATE TABLE portal_teachers (id INT PRIMARY KEY, user_id INT);
DROP TABLE IF EXISTS portal_teacher_clazzes;
CREATE TABLE portal_teacher_clazzes (id INT PRIMARY KEY, clazz_id INT, teacher_id INT);
DROP TABLE IF EXISTS portal_student_clazzes;
CREATE TABLE portal_student_clazzes (id INT PRIMARY KEY, clazz_id INT, student_id INT);
DROP TABLE IF EXISTS portal_offerings;
CREATE TABLE portal_offerings (id INT PRIMARY KEY, runnable_type VARCHAR(255), runnable_id INT, clazz_id INT);
DROP TABLE IF EXISTS external_activities;
CREATE TABLE external_activities (id INT PRIMARY KEY, name VARCHAR(255), url TEXT);
DROP TABLE IF EXISTS portal_learners;
CREATE TABLE portal_learners (id INT PRIMARY KEY, student_id INT, offering_id INT, secure_key VARCHAR(255), created_at DATETIME NOT NULL);
DROP TABLE IF EXISTS portal_runs;
CREATE TABLE portal_runs (id INT PRIMARY KEY, learner_id INT);
DROP TABLE IF EXISTS portal_student_permission_forms;
CREATE TABLE portal_student_permission_forms (id INT PRIMARY KEY, portal_student_id INT, portal_permission_form_id INT);
DROP TABLE IF EXISTS admin_cohorts;
CREATE TABLE admin_cohorts (id INT PRIMARY KEY, name VARCHAR(255), project_id INT);
DROP TABLE IF EXISTS admin_cohort_items;
CREATE TABLE admin_cohort_items (id INT PRIMARY KEY, admin_cohort_id INT, item_type VARCHAR(255), item_id INT);
DROP TABLE IF EXISTS admin_projects;
CREATE TABLE admin_projects (id INT PRIMARY KEY, name VARCHAR(255));
DROP TABLE IF EXISTS portal_clazzes;
CREATE TABLE portal_clazzes (id INT PRIMARY KEY, name VARCHAR(255), class_word VARCHAR(255));
DROP TABLE IF EXISTS portal_students;
CREATE TABLE portal_students (id INT PRIMARY KEY, user_id INT);
DROP TABLE IF EXISTS portal_permission_forms;
CREATE TABLE portal_permission_forms (id INT PRIMARY KEY, name VARCHAR(255), project_id INT);
DROP TABLE IF EXISTS portal_countries;
CREATE TABLE portal_countries (id INT PRIMARY KEY, name VARCHAR(255));
DROP TABLE IF EXISTS admin_tags;
CREATE TABLE admin_tags (id INT PRIMARY KEY, tag VARCHAR(255), scope VARCHAR(255));
DROP TABLE IF EXISTS taggings;
CREATE TABLE taggings (id INT PRIMARY KEY, tag_id INT, context VARCHAR(255), taggable_type VARCHAR(255), taggable_id INT);
DROP TABLE IF EXISTS admin_project_materials;
CREATE TABLE admin_project_materials (id INT PRIMARY KEY, project_id INT, material_type VARCHAR(255), material_id INT);
DROP TABLE IF EXISTS admin_project_users;
CREATE TABLE admin_project_users (id INT PRIMARY KEY, project_id INT, user_id INT, is_admin TINYINT(1), is_researcher TINYINT(1));
DROP TABLE IF EXISTS report_learners;
CREATE TABLE report_learners (
  id INT PRIMARY KEY AUTO_INCREMENT,
  learner_id INT, student_id INT, user_id INT, offering_id INT, class_id INT,
  last_run DATETIME NULL,
  teachers_name VARCHAR(255), student_name VARCHAR(255), username VARCHAR(255),
  school_name VARCHAR(255), class_name VARCHAR(255), school_id INT,
  permission_forms MEDIUMTEXT,
  teachers_district VARCHAR(255), teachers_state VARCHAR(255), teachers_email VARCHAR(255),
  permission_forms_id VARCHAR(255), teachers_id VARCHAR(255),
  INDEX index_report_learners_on_learner_id (learner_id)
);
INSERT INTO users VALUES
  (101,'stu.one','Stu','One','stu.one@e.org',NULL),
  (102,'stu.two','Stu','Two','stu.two@e.org',NULL),
  (103,'stu.three','Stu','Three','stu.three@e.org',NULL),
  (104,'stu.four','Stu','Four','stu.four@e.org',NULL),
  (131,'ann','Ann','Teach','ann@e.org',NULL),
  (135,'eve','Eve','Internal','eve@concord.org',NULL),
  (132,'bob','Bob','Teach','bob@e.org',NULL),
  (133,'cid','Cid','Teach','cid@e.org',NULL);
-- Dist Y's comma is deliberate: the report joins district names on commas and must scrub them
INSERT INTO portal_districts VALUES (41,'Dist W','NH'), (42,'Dist Y, Region 2','MA');
-- get_internal_teacher_ids/1 matches schools named like '%concord consortium%', so school 53 is
-- what makes the exclude_internal flag observable.
INSERT INTO portal_schools VALUES (51,'School W',41,'NH',1), (52,'School Y',42,'MA',1),
  (53,'Concord Consortium',41,'NH',1);
INSERT INTO portal_school_memberships VALUES
  (1,31,'Portal::Teacher',51), (2,31,'Portal::Teacher',52), (3,32,'Portal::Teacher',52),
  (4,35,'Portal::Teacher',53);
INSERT INTO portal_teachers VALUES (31,131),(32,132),(33,133),(35,135);
INSERT INTO portal_teacher_clazzes VALUES (1,601,31),(2,601,32),(3,602,31),(4,602,33),(5,602,34);
INSERT INTO portal_student_clazzes VALUES (1,601,71),(2,601,72),(3,602,73),(4,602,74);
INSERT INTO portal_offerings VALUES (701,'ExternalActivity',801,601),(702,'ExternalActivity',802,601),(703,'ExternalActivity',801,602);
INSERT INTO external_activities VALUES
  (801,'Activity One','https://activity.example.org/a?answersSourceKey=src.example.org'),
  (802,'Activity Two',NULL);
INSERT INTO portal_learners VALUES
  (901,71,701,'SECUREKEY123','2026-04-01 09:00:00'),
  (902,72,702,NULL,'2026-04-02 09:00:00'),
  (903,73,703,'SECUREKEY903','2026-04-03 09:00:00'),
  (904,74,703,'SECUREKEY904','2026-04-04 09:00:00');
INSERT INTO portal_runs VALUES (1,901),(2,901);
INSERT INTO portal_student_permission_forms VALUES (1,71,11),(2,71,12),(3,71,13);
INSERT INTO admin_cohorts VALUES (1,'Cohort One',900),(2,'Cohort Two',901);
INSERT INTO admin_cohort_items VALUES (1,1,'Portal::Teacher',31),(2,1,'ExternalActivity',801),(3,1,'Portal::Teacher',35);
INSERT INTO admin_projects VALUES (900,'Proj A'),(901,'Proj B');
INSERT INTO portal_countries VALUES (1,'United States'),(2,'Canada');
-- Form 13's name sorts before the others while its project sorts after, so ordering by the form
-- name and ordering by the displayed "project: form" label give different answers.
INSERT INTO portal_permission_forms VALUES (11,'Form 1',900),(12,'Form 2',901),(13,'Aardvark Form',901);
INSERT INTO portal_students VALUES (71,101),(72,102),(73,103),(74,104);
INSERT INTO admin_tags VALUES (1,'Science','subject_areas'),(2,'Math','subject_areas'),(3,'Not A Subject','other');
INSERT INTO taggings VALUES (1,1,'subject_areas','ExternalActivity',801);
-- Three classes share a label so a page boundary can fall inside the tie, and their ids disagree
-- numerically and lexicographically. Two classes have no class word, so CONCAT yields a NULL label
-- for each. Two rather than one, so a page of size one ends on a NULL cursor with another NULL
-- still to visit, which is the only shape that catches an ordering that is not null safe.
INSERT INTO portal_clazzes VALUES
  (2,'Adams','a'),(3,'No Word',NULL),(4,'No Word Two',NULL),(5,'Lincoln High','sec'),
  (9,'Lincoln High','sec'),(40,'Lincoln High','sec'),(77,'Zed','z'),
  (601,'Class 601','c'),(602,'Class 602','c');
INSERT INTO portal_teacher_clazzes VALUES
  (10,2,31),(11,3,31),(12,5,31),(13,9,31),(14,40,31),(15,77,31),(16,4,31);
INSERT INTO admin_project_materials VALUES (1,900,'ExternalActivity',801);
INSERT INTO admin_project_users VALUES (1,900,555,1,0),(2,900,557,0,1);
INSERT INTO report_learners
  (learner_id,student_id,user_id,offering_id,class_id,last_run,teachers_name,student_name,username,
   school_name,class_name,school_id,permission_forms,teachers_district,teachers_state,teachers_email,
   permission_forms_id,teachers_id)
VALUES
  (901,71,101,701,601,'2026-05-01 10:00:00','Ann Teach, Bob Teach','Stu One','stu.one',
   'School W','Class 601',51,'Proj A: Form 1,Proj B: Form 2','Dist W, Dist Y, Dist Y','NH, MA, MA',
   'ann@e.org, bob@e.org','11,12','31, 32'),
  (902,72,102,702,601,NULL,'Ann Teach, Bob Teach','Stu Two','stu.two',
   'School W','Class 601',51,NULL,NULL,NULL,'ann@e.org, bob@e.org','','31, 32'),
  (903,73,101,703,602,'2026-05-02 11:00:00','Ann Teach, Cid Teach, Gone Teach','Stu Three','stu.three',
   'School W','Class 602',51,NULL,'Dist W, Dist Y','NH, MA','ann@e.org, cid@e.org, gone@e.org','','31, 33, 34'),
  (904,74,102,703,602,NULL,NULL,'Stu Four','stu.four',
   'School W','Class 602',51,NULL,NULL,NULL,NULL,NULL,NULL);
