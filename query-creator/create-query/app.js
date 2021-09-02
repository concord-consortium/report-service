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
    console.time("before for loop");
    const params = event.queryStringParameters || {};

    // get the report service source from the url
    const reportServiceSource = params.reportServiceSource;
    const debugSQL = params.debugSQL || false;
    const tokenServiceEnv = params.tokenServiceEnv;
    const usageReport = params.usageReport || false;

    if (!reportServiceSource) {
      throw new Error("Missing reportServiceSource in the report url");
    }
    if (!tokenServiceEnv) {
      throw new Error("Missing tokenServiceEnv in the report url");
    }

    // ensure all the environment variables exist
    envVars.validate();

    // get the post body
    console.time("request.getBody");
    const body = request.getBody(event);
    console.timeEnd("request.getBody");
    console.time("request.validateRequestBody");
    request.validateRequestBody(body);
    console.timeEnd("request.validateRequestBody");
    const { json, jwt } = body;
    const { query, learnersApiUrl, user } = json;
    let { email } = user;

    const portalUrl = learnersApiUrl.match(/(.*)\/api\/v[0-9]+/)[1];

    const authDomain = portalToAuthDomainMap[portalUrl] || portalUrl;

    console.time("request.getTokenServiceJwt");
    const tokenServiceJwt = await request.getTokenServiceJwt(portalUrl, jwt);
    console.timeEnd("request.getTokenServiceJwt");

    console.time("tokenService.findOrCreateResource");
    const resource = await tokenService.findOrCreateResource(tokenServiceJwt, tokenServiceEnv, email, portalUrl);
    console.timeEnd("tokenService.findOrCreateResource");

    console.time("aws.ensureWorkgroup");
    const workgroupName = await aws.ensureWorkgroup(resource, user);
    console.timeEnd("aws.ensureWorkgroup");

    console.time("aws.fetchAndUploadLearnerData");
    const queryIdsPerRunnable = await aws.fetchAndUploadLearnerData(jwt, query, learnersApiUrl);
    console.timeEnd("aws.fetchAndUploadLearnerData");

    const sqlOutput = [];

    console.timeEnd("before for loop");
    for (const runnableUrl in queryIdsPerRunnable) {
      console.log("for loop", runnableUrl);
      console.time("full for loop");
      const queryId = queryIdsPerRunnable[runnableUrl];

      // get and denormalize the resource (activity or sequence) from Firebase
      let resource;
      let denormalizedResource;
      try {
        console.log("start firebase.getResource", runnableUrl, reportServiceSource);
        console.time("firebase.getResource", runnableUrl, reportServiceSource)
        resource = await firebase.getResource(runnableUrl, reportServiceSource);
        console.timeEnd("firebase.getResource", runnableUrl, reportServiceSource);

        console.log("start denormalizeResource");
        console.time("denormalizeResource");
        denormalizedResource = firebase.denormalizeResource(resource);
        console.timeEnd("denormalizeResource");

        // upload the denormalized resource to s3 and tie it to the workgroup
        console.log("start uploadDenormalizedResource");
        console.time("uploadDenormalizedResource");
        await aws.uploadDenormalizedResource(queryId, denormalizedResource);
        console.timeEnd("uploadDenormalizedResource");
      } catch (err) {
        // no valid resource, we will attempt to create a usage report with just the learner data
        console.log(err);
      }

      // generate the sql for the query
      console.log("start generateSQL");
      console.time("generateSQL");
      const sql = aws.generateSQL(queryId, resource, denormalizedResource, usageReport, runnableUrl, authDomain);
      console.timeEnd("generateSQL");

      if (debugSQL) {
        sqlOutput.push(`${resource ? `-- id ${resource.id}` : `-- url ${runnableUrl}`}\n${sql}`);
      } else {
        // create the athena query in the workgroup
        console.log("start startQueryExecution");
        console.time("startQueryExecution");
        await aws.startQueryExecution(sql, workgroupName)
        console.timeEnd("startQueryExecution");
      }
      console.timeEnd("full for loop");
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
