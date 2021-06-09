# query-creator

This project contains source code and supporting files for a serverless application that you can deploy with the SAM CLI.

## Developing

The Serverless Application Model Command Line Interface (SAM CLI) is an extension of the AWS CLI that adds functionality for building and testing Lambda applications. It uses Docker to run your functions in an Amazon Linux environment that matches Lambda. It can also emulate your application's build environment and API.

To use the SAM CLI, you need the following tools.

* SAM CLI - [Install the SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
* Node.js - [Install Node.js 10](https://nodejs.org/en/), including the NPM package management tool.
* Docker - [Install Docker community edition](https://hub.docker.com/search/?type=edition&offering=community)

## Deploying

Deploying currently involves three steps:

1. Switching to the appropriate role in the CLI
2. Running the deploy script
3. Copying in secrets from the CloudFormation stack

### Deploying staging

The following profile needs to be added to the ~/.aws/config file that is created by the CLI, to allow you to switch
to the AdminConcordQA role. It assumes that there is already a profile named `default` with admin privileges in the
main account:

```
[profile concord-qa]
role_arn = arn:aws:iam::816253370536:role/AdminConcordQA
source_profile = default
region = us-east-1
```

1. Switch to the QA role: `export AWS_PROFILE="concord-qa"`
2. Run the deploy script with the staging properties: `sam deploy --guided --config-env=staging`
3. Accept all the defaults (just hit enter) except
  1. For any non-filled-in secrets (e.g. the ReportServiceToken) find the report-service-query-creator CloudFormation
     stack under the QA account, switch to the Parameters tab, and copy and paste the values
  2. For "CreateQueryFunction may not have authorization defined, Is this okay?" answer `y`
4. If there aren't unexpected changes staged, answer `y` to "Deploy this changeset?"
5. If new secrets were written to the samconfig.toml file, edit them out before committing changes

### Deploying production

1. Switch to your default role: `export AWS_PROFILE="default"`
2. Run the deploy script with the production properties: `sam deploy --guided --config-env=production`

Follow the rest of the steps from step 3 of "Deploying staging", using the CloudFormation stack from the
production account.

### Deployment properties

These should all be defined in the samconfig.toml, but here is what they mean:

* **Stack Name**: The name of the stack to deploy to CloudFormation. This should be unique to your account and region, and a good starting point would be something matching your project name.
* **AWS Region**: The AWS region you want to deploy your app to.
* **Confirm changes before deploy**: If set to yes, any change sets will be shown to you before execution for manual review. If set to no, the AWS SAM CLI will automatically deploy application changes.
* **Allow SAM CLI IAM role creation**: Many AWS SAM templates, including this example, create AWS IAM roles required for the AWS Lambda function(s) included to access AWS services. By default, these are scoped down to minimum required permissions. To deploy an AWS CloudFormation stack which creates or modified IAM roles, the `CAPABILITY_IAM` value for `capabilities` must be provided. If permission isn't provided through this prompt, to deploy this example you must explicitly pass `--capabilities CAPABILITY_IAM` to the `sam deploy` command.
* **Save arguments to samconfig.toml**: If set to yes, your choices will be saved to a configuration file inside the project, so that in the future you can just re-run `sam deploy` without parameters to deploy changes to your application.

You can find your API Gateway Endpoint URL in the output values displayed after deployment.

## Use the SAM CLI to build and test locally

Add `QueryCreatorLocalTestUser` credential information to your `~/.aws/credentials` file. This can be done manually by editing the credentials file and adding the following (`aws_access_key_id` and `aws_secret_access_key` values can be obtained from 1Password):
```
[QueryCreatorLocalTestUser]
aws_access_key_id = XXXXXXX
aws_secret_access_key = XXXXXXX
```

Or the `QueryCreatorLocalTestUser` credential information can be configured via the `aws configure` command (requires installation of AWS CLI).

```bash
query-creator$ aws configure
```

The following environment variables need to be configured: `OutputBucket`, `ReportServiceToken`, `ReportServiceUrl`. These can be configured system-wide or as default values in the `parameters` section of `template.yml`. For example, `OutputBucket` can be configured as follows:
```
  OutputBucket:
    Type: String
    Description: Output bucket for Athena queries
    Default: 'concordqa-report-data'
```

The environment variable values can be found on the production AWS account under `Cloud formation > Stacks` (for example, the `report-service-query-creator` stack can be used to obtain `OutputBucket`, `ReportServiceToken`, `ReportServiceUrl` values).

Build your application with the `sam build` command.

```bash
query-creator$ sam build
```

The SAM CLI installs dependencies defined in `create-query/package.json`, creates a deployment package, and saves it in the `.aws-sam/build` folder.

Test a single function by invoking it directly with a test event. An event is a JSON document that represents the input that the function receives from the event source. Test events are included in the `events` folder in this project.

Run functions locally and invoke them with the `sam local invoke` command.

```bash
query-creator$ sam local invoke CreateQueryFunction --event events/event.json
```

The SAM CLI can also emulate your application's API. Use the `sam local start-api` to run the API locally on port 3000.

```bash
query-creator$ sam local start-api
query-creator$ curl http://localhost:3000/
```

The SAM CLI reads the application template to determine the API's routes and the functions that they invoke. The `Events` property on each function's definition includes the route and method for each path.

```yaml
      Events:
        CreateQuery:
          Type: Api
          Properties:
            Path: /hello
            Method: get
```

### Testing locally with the portal running locally

When the portal makes its request to the query-creator, it passes a `reportServiceUrl` that points back to the
API endpoint we can use to make the requests for the learner data.

However, if the portal is running in Docker and the SAM application is as well, it's tricky to get them to talk
to each other.

While there is probably a much better Docker-ish way to solve this, one hacky solution is to

1. Install [ngrok](https://ngrok.com/), or a similar service to allow you to create a public url for your local servers
2. Take note of the port that the app is running on in your Docker UI
3. Publish that port with ngrok and get back a public url
4. Hardcode `{public_url}/api/v1/report_learners_es/external_report_learners_from_jwt` in the query-creator app as the `reportServiceUrl`

## Add a resource to your application
The application template uses AWS Serverless Application Model (AWS SAM) to define application resources. AWS SAM is an extension of AWS CloudFormation with a simpler syntax for configuring common serverless application resources such as functions, triggers, and APIs. For resources not included in [the SAM specification](https://github.com/awslabs/serverless-application-model/blob/master/versions/2016-10-31.md), you can use standard [AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html) resource types.

## Fetch, tail, and filter Lambda function logs

To simplify troubleshooting, SAM CLI has a command called `sam logs`. `sam logs` lets you fetch logs generated by your deployed Lambda function from the command line. In addition to printing the logs on the terminal, this command has several nifty features to help you quickly find the bug.

`NOTE`: This command works for all AWS Lambda functions; not just the ones you deploy using SAM.

```bash
query-creator$ sam logs -n CreateQueryFunction --stack-name query-creator --tail
```

You can find more information and examples about filtering Lambda function logs in the [SAM CLI Documentation](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-logging.html).

## Unit tests

Tests are defined in the `hello-world/tests` folder in this project. Use NPM to install the [Mocha test framework](https://mochajs.org/) and run unit tests.

```bash
query-creator$ cd hello-world
hello-world$ npm install
hello-world$ npm run test
```

## Cleanup

To delete the sample application that you created, use the AWS CLI. Assuming you used your project name for the stack name, you can run the following:

```bash
aws cloudformation delete-stack --stack-name query-creator
```

## Resources

See the [AWS SAM developer guide](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html) for an introduction to SAM specification, the SAM CLI, and serverless application concepts.

Next, you can use AWS Serverless Application Repository to deploy ready to use Apps that go beyond create query samples and learn how authors developed their applications: [AWS Serverless Application Repository main page](https://aws.amazon.com/serverless/serverlessrepo/)


## AWS Glue/Athena Setup

1. Create a `report-service` database in AWS Glue.
2. If running on production, replace all instances of `concordqa-report-data` below with `concord-report-data`, or
   any other location as appropriate
2. In Athena with the `report-service` database selected run the following:

    ```
    CREATE EXTERNAL TABLE IF NOT EXISTS activity_structure (
      choices map<string,map<string,struct<content:string,correct:boolean>>>,
      questions map<string,struct<prompt:string,required:boolean,type:string>>
    )
    PARTITIONED BY
    (
        structure_id STRING
    )
    ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
    LOCATION "s3://concordqa-report-data/activity-structure/"
    TBLPROPERTIES
    (
        "projection.enabled" = "true",
        "projection.structure_id.type" = "injected",
        "storage.location.template" = "s3://concordqa-report-data/activity-structure/${structure_id}"
    )

    CREATE EXTERNAL TABLE IF NOT EXISTS learners (
      learner_id string,
      run_remote_endpoint string,
      class_id int,
      runnable_url string,
      student_id string,
      class string,
      school string,
      user_id string,
      permission_forms string,
      username string,
      student_name string,
      teachers array<struct<user_id: string, name: string, district: string, state: string, email: string>>,
      last_run string
    )
    PARTITIONED BY
    (
        query_id STRING
    )
    ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
    LOCATION "s3://concordqa-report-data/learners/"
    TBLPROPERTIES
    (
        "projection.enabled" = "true",
        "projection.query_id.type" = "injected",
        "storage.location.template" = "s3://concordqa-report-data/learners/${query_id}"
    )

    CREATE EXTERNAL TABLE IF NOT EXISTS partitioned_answers (
      submitted boolean,
      run_key string,
      platform_user_id string,
      id string,
      context_id string,
      class_info_url string,
      platform_id string,
      resource_link_id string,
      type string,
      question_id string,
      source_key string,
      question_type string,
      tool_user_id string,
      answer string,
      resource_url string,
      remote_endpoint string,
      created string,
      tool_id string,
      version string
    )
    PARTITIONED BY
    (
        escaped_url STRING
    )
    ROW FORMAT SERDE 'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
    LOCATION "s3://concordqa-report-data/partitioned-answers/"
    TBLPROPERTIES
    (
        "projection.enabled" = "true",
        "projection.escaped_url.type" = "injected",
        "storage.location.template" = "s3://concordqa-report-data/partitioned-answers/${escaped_url}"
    )
    ```