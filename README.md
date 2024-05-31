# Report Service

This repo contains a series of related projects that enable researchers to run reports on portal learner data.

A detailed description of the system can be found at https://docs.google.com/document/d/1F4ozfQOjzZfMMYdGiPp0MGWpAxjTbMa6lDIvPSnuNcI/

The high-level parts:

* **Scripts**: Pushes old learner data from Firestore into S3, for access by Athena. See
    [scripts/README.md](scripts/README.md)
* **Functions**: Keeps new learner data synced to S3 and updates collaborator answers.
    The functions also provide the API used by LARA to send learner data and activity structure to FireStore,
    and an API used by the portal to move learner data from one class to another. See [functions/README.md](functions/README.md).
* **Query-Creator**: A Lambda application written with AWS SAM which is launched by the portal as an
    external report. It collects together all the data that Athena will need to run a query, constructs
    the SQL for the query, and kicks off an Athena query under a personal workgroup for the researcher.
    See [query-creator/README.md](query-creator/README.md)
* **Researcher-Reports**: An application a researcher can use to list their reports and generate a
    short-lived url to download the data. See [researcher-reports/README.md](researcher-reports/README.md)
    **NOTE**: this app is no longer used and instead the Elixir/Phoenix app in the server folder is used.
* **Report-Server**: An Elixir/Phoenix app that replaces the **Researcher-Reports** app.  It allows for long-running processes
    to post-process log files.

## Setting up a new report on a portal

1. Add new external report from the portal's admin section. The URL should be to the query-creator
   API endpoint, plus two url parameters, `reportServiceSource`, which points to the source used for the
   report service API, and `tokenServiceEnv`, which is the env name for the token-service. E.g.
   ```
     https://bn84q7k6u0.execute-api.us-east-1.amazonaws.com/Prod/create-query/?reportServiceSource=authoring.staging.concord.org&tokenServiceEnv=staging
   ```
2. Ensure there is a resourceSettings doc for the tool `researcher-report` for the appropriate token-service
   env. For example, the one for staging is at
   https://console.firebase.google.com/project/token-service-staging/firestore/data~2Fstaging:resourceSettings~2FmIVQo4W7ZwjGr0v4in8W
   See https://github.com/concord-consortium/token-service/#creating-new-athenaworkgrouptools for details.
3. Ensure there is an Auth client in the portal (found in the admin section) for the researcher-reports app
   that includes the portal domain as a url parameter in the Allowed Redirect URIs list. For portals that
   launch reports from another domain, that other domain should be included as well. E.g.
   ```
     https://researcher-reports.concord.org/?portal=https%3A%2F%2Flearn.concord.org
     https://researcher-reports.concord.org/?portal=https%3A%2F%2Flearn-report.concord.org
   ```

## Notes on inter-app environment variables, query parameters, and staging/production versions

There are two deployed versions of the Query Creator, one for staging (deployed under the AdminConcordQA account) and
one for production. The Query Creator app requires a `RESEARCHER_REPORTS_URL`. By default, the SAM template that
is used on deployment sets this to `researcher-reports.concord.org/` on production and `.../branch/master/` on staging.

The Query Creator gets launched with a url that includes two url parameters, `reportServiceSource`, which points to the
source used for the report service API, and `tokenServiceEnv`, which is the env name for the token-service. This second
parameter needs to be set to `staging` or `production`.

The JWT that is sent to the Query Creator contains a `learnersApiUrl` which is used to extract a `portalUrl`.

After the query is initiated on Athena, the Query Creator will redirect to the `RESEARCHER_REPORTS_URL` with the
query parameter `portal={portalUrl}`. This is needed by the Researcher Report to log the user into the correct portal.
The Researcher Report also needs to know the `tokenServiceEnv`, but this is hard-coded in the app to be `production`
when the app is running on the production url, and `staging` otherwise.

## Other stuff

### Notes on URLs generated for details / answer reports

The researcher details or answer report includes links so researchers can open an interactive and see what a teacher would see in the teacher report.

These links use the portal report to render the interactive and pass it the student's saved state. We cannot let just any user open a student's saved state so the portal report first authenticates the researcher via the portal. If the researcher has permission to view that student's work then a JWT token is returned to the portal report that includes a special `target_user_id`. The Firestore access rules in the report-service look for this `target_user_id` and authorize the researcher to download their work.

Details of the authentication process and the parameters of these links are described here:
https://github.com/concord-consortium/portal-report/blob/master/docs/launch.md

For reference here is an example link:
```
https://portal-report.concord.org/branch/master/index.html
?auth-domain=https%3A%2F%2Flearn.concord.org
&firebase-app=report-service-pro
&sourceKey=authoring.concord.org
&iframeQuestionId=mw_interactive_104182
&class=https%3A%2F%2Flearn.concord.org%2Fapi%2Fv1%2Fclasses%2F60888
&offering=https%3A%2F%2Flearn.concord.org%2Fapi%2Fv1%2Fofferings%2F135999
&studentId=1063089
&answersSourceKey=activity-player.concord.org
```
### Anonymous Reports

Currently per student reports are supported using the run_key property of student work documents.

#### Anonymous Class reports

These aren't currently supported, but they could be.

For student work this could be extended to support anonymous class reports using anonymous `resource_link_id`
property. This would let a teacher view a report of multiple anonymous students that ran from
a the same "resource link".  The rules do not allow a request for a resource_link_id based
query of the answers, so they would need to be updated.

For user settings, it doesn't seem to make a lot of sense to support user settings for anonymous
teachers. However this might cause problems in the portal-report code, so that probably needs updating

For feedback, we'd need a new read option that matches a context_id, resource_link_id, and run_key
One of the reasons to support anonymous feedback is to simplify testing, but if the data and code paths
for this anonymous feedback is different it won't be as good for testing.
So switching from run_key to platform_user_id (see below) might simplify the code paths

### Possible improvement of run_key approach

Our 'run_key' essentially represents: (platform_id, platform_user_id, resource_link_id)
So we might be able to simplify some of the logic here by using those 3 properties instead of a run_key
- The platform_id should be left unset since that is how the anonymous rules prevent injecting
data into the authenticated data.
- The platform_user_id could be the randomly generated 'run_key'
- The resource_link_id would be an optional randomly generated id that can correlate
multiple platform_users so a teacher gets an anonymous class report.

If we follow that to its conclusion would also allow students/teachers to re-use the
same anonymous platform_user_id for multiple anonymous assignments. There isn't a great
reason to use this right away, but it would match the current logged in case better.
In the future it would allow anonymous teachers to correlate data across multiple assignments
for a single student. The issue is that most LMS would not support something like this
out of the box. They'd need some option which lets the user supply a template for the URL which
the LMS then populates with a student id. So using generic LMS support the student would need
to know their special id and paste it into some field when they run the activity.

### Possible improvements for data validity

The rules are not currently checking the resource_link_id (or resourceLinkId). In some
cases this property is required for the documents to be valid. It is often queried on by the
portal-report code. The rules could be updated to enforce that it is set and used in queries.

The rules do not check that the platformStudentId is set for question_feedbacks and
activity_feedbacks. These documents are specific to students and should have this property
set on all of them.

The user settings are stored under a path that includes the platform_user_id. The rules
only check that this id in the path matches the authorized platform_user_id. It would be
better if the rules also checked the platform_id since the platform_user_id could overlap
between different platforms.
