const envVars = require("./steps/env-vars");
const request = require("./steps/request");
const firebase = require("./steps/firebase");
const aws = require("./steps/aws");
const tokenService = require("./steps/token-service");

const portalToAuthDomainMap = {
  "https://learn-report.staging.concord.org": "https://learn.staging.concord.org",
  "https://learn-report.concord.org": "https://learn.concord.org"
}

exports.lambdaHandler = async (event, context) => {
  try {
    const params = event.queryStringParameters || {};

    // get the report service source from the url
    const reportServiceSource = params.reportServiceSource;
    const debugSQL = params.debugSQL || false;
    const tokenServiceEnv = params.tokenServiceEnv;
    const usageReport = params.usageReport || false;
    const useLogs = params.useLogs || false;
    const endpoint_only = params.endpoint_only || false

    if (!reportServiceSource) {
      throw new Error("Missing reportServiceSource in the report url");
    }
    if (!tokenServiceEnv) {
      throw new Error("Missing tokenServiceEnv in the report url");
    }

    // ensure all the environment variables exist
    envVars.validate();

    // get the post body
    const body = request.getBody(event);
    request.validateRequestBody(body);
    const { json, jwt } = body;
    const { query, learnersApiUrl, user } = json;
    let { email } = user;

    const portalUrl = learnersApiUrl.match(/(.*)\/api\/v[0-9]+/)[1];

    const authDomain = portalToAuthDomainMap[portalUrl] || portalUrl;

    const tokenServiceJwt = await request.getTokenServiceJwt(portalUrl, jwt);

    const resource = await tokenService.findOrCreateResource(tokenServiceJwt, tokenServiceEnv, email, portalUrl);
    const workgroupName = await aws.ensureWorkgroup(resource, user);

    const queryIdsPerRunnable = await aws.fetchAndUploadLearnerData(jwt, query, learnersApiUrl, endpoint_only);

    const sqlOutput = [];

    const doLearnerAnswerReporting = async (runnableUrl) => {
      const queryId = queryIdsPerRunnable[runnableUrl];

      // get and denormalize the resource (activity or sequence) from Firebase
      let resource;
      let denormalizedResource;
      try {
        resource = await firebase.getResource(runnableUrl, reportServiceSource);
        denormalizedResource = firebase.denormalizeResource(resource);

        // upload the denormalized resource to s3 and tie it to the workgroup
        await aws.uploadDenormalizedResource(queryId, denormalizedResource);
      } catch (err) {
        // no valid resource, we will attempt to create a usage report with just the learner data
        console.log(err);
      }

      // generate the sql for the query
      const sql = aws.generateSQL(queryId, resource, denormalizedResource, usageReport, runnableUrl, authDomain, reportServiceSource);

      if (debugSQL) {
        sqlOutput.push(`${resource ? `-- id ${resource.id}` : `-- url ${runnableUrl}`}\n${sql}`);
      } else {
        // create the athena query in the workgroup
        await aws.startQueryExecution(sql, workgroupName)
      }
    }

    const doLearnerLogReporting= async (runnableUrl) => {
      const queryId = queryIdsPerRunnable[runnableUrl];

      // generate the sql for the query
      const sql = aws.generateLogSQL(queryId, runnableUrl, authDomain, reportServiceSource);

      if (debugSQL) {
        sqlOutput.push(`-- url ${runnableUrl}\n${sql}`);
      } else {
        // create the athena query in the workgroup
        await aws.startQueryExecution(sql, workgroupName)
      }
    };

    for (const runnableUrl in queryIdsPerRunnable) {
      if(useLogs) {
        await doLearnerLogReporting(runnableUrl);
      }
      else {
        await doLearnerAnswerReporting(runnableUrl);
      }
    }

    let message = sqlOutput.length ? sqlOutput.join("\n\n------\n\n") : "Success"

    if (debugSQL) {
      return {
        statusCode: 200,
        body: message
      }
    } else {
      const escapedPortalUrl = encodeURIComponent(portalUrl)
      const reportsUrl =  `${process.env.RESEARCHER_REPORTS_URL}?portal=${escapedPortalUrl}`
      message += "\n\nRedirecting to " + reportsUrl;

      return {
        statusCode: 302,
        headers: {
          Location: reportsUrl,
        },
        body: message
      }
    }
  } catch (err) {
    console.log(err);
    return {
      statusCode: 500,
      body: JSON.stringify({
        error: err.toString(),
        stack: err.stack
      }, null, 2)
    }
  }
};
