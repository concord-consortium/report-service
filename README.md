# Report Service

This repo contains a series of related projects that enable researchers to run reports on portal learner data.

A detailed description of the system can be found at https://docs.google.com/document/d/1F4ozfQOjzZfMMYdGiPp0MGWpAxjTbMa6lDIvPSnuNcI/

The high-level parts:

* **Scripts**: Pushes old learner data from Firestore into S3, for access by Athena. See
    [scripts/README.md](scripts/README.md)
* **Functions**: Keeps new learner data synced to S3, as well as activity structures. See
     [functions/README.md](functions/README.md)
* **Query-Creator**: A Lambda application written with AWS SAM which is launched by the portal as an
    external report. It collects together all the data that Athena will need to run a query, constructs
    the SQL for the query, and kicks off an Athena query under a personal workgroup for the researcher.
    See [query-creator/README.md](query-creator/README.md)
* **Researcher-Reports**: An application a researcher can use to list their reports and generate a
    short-lived url to download the data. See [researcher-reports/README.md](researcher-reports/README.md)

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
3. Ensure there is an Auth client in the portal (for in the admin section) for the researcher-reports app
   that includes the portal domain as a url parameter in the Allowed Redirect URIs list. For portals that
   launch reports from another domain, that other domain should be included as well. E.g.
   ```
     https://researcher-reports.concord.org/?portal=https%3A%2F%2Flearn.concord.org
     https://researcher-reports.concord.org/?portal=https%3A%2F%2Flearn-report.concord.org
   ```


## Other stuff


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
