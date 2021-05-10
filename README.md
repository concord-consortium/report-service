# Report Service
Ingest student runs and activity structure in order to run report queries later.

## Scripts

Includes the export-answers script for copying all student answers from Firestore into S3 as Parquet files

See [scripts/README.md](scripts/README.md)

## Firebase functions

Includes the API and the auto-update function for student answers.

See [functions/README.md](functions/README.md)

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
