# User Policies

There are two JSON docs in this directory that contain the IAM user policy needed to run the server on AWS.  These policies are not part of any CloudFormation template so they will need to be recreated in the future if either the production user (on the main AWS account) or the staging user (on the QA account) are ever accidentally deleted.

The ported statements to allow AWS Athena/Glue access in the policy docs were ported from the SAM template in the old create-query SAM app.