const envVars = require("./steps/env-vars");
const request = require("./steps/request");
const firebase = require("./steps/firebase");
const aws = require("./steps/aws");
const tokenService = require("./steps/token-service");

const portalToAuthDomainMap = {
  "https://learn-report.staging.concord.org": "https://learn.staging.concord.org",
  "https://learn-report.concord.org": "https://learn.concord.org",
}

const trimTrailingSlash = (s) => s.trim().replace(/\/$/, "");

const ensureWorkgroup = async (portalUrl, jwt, tokenServiceEnv, email) => {
  const tokenServiceJwt = await request.getTokenServiceJwt(portalUrl, jwt);
  const resource = await tokenService.findOrCreateResource(tokenServiceJwt, tokenServiceEnv, email, portalUrl);
  const workgroupName = await aws.ensureWorkgroup(resource, email);

  return workgroupName;
}

const userReport = async (body, tokenServiceEnv, debugSQL) => {
  const { json, portal_token } = body;
  const { user, portal_url, domain, users, runnables, start_date, end_date } = json;

  const portalUrl = trimTrailingSlash(portal_url);

  const workgroupName = await ensureWorkgroup(portalUrl, portal_token, tokenServiceEnv, user.email);

  const usernames = users.map(u => `${u.id}@${domain}`);
  const activities = runnables.map(r => r.url);

  const sql = aws.generateUserLogSQL(usernames, activities, start_date, end_date);

  const sqlOutput = [];

  if (debugSQL) {
    sqlOutput.push(sql);
  } else {
    await aws.startQueryExecution(sql, workgroupName)
  }

  return {portalUrl, sqlOutput}
}

const learnersReport = async (params, body, tokenServiceEnv, debugSQL, reportServiceSource) => {
  const usageReport = params.usageReport || false;
  const useLogs = params.useLogs || false;
  const narrowLearners = params.narrowLearners || false

  const { json, jwt } = body;
  const { query, portal_url, learnersApiUrl, user } = json;
  let { email } = user;

  const portalUrl = trimTrailingSlash(portal_url);

  const authDomain = portalToAuthDomainMap[portalUrl] || portalUrl;

  const workgroupName = await ensureWorkgroup(portalUrl, jwt, tokenServiceEnv, email);

  const queryIdsPerRunnable = await aws.fetchAndUploadLearnerData(jwt, query, learnersApiUrl, narrowLearners);

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
    const sql = narrowLearners
      ? aws.generateNarrowLogSQL(queryId, runnableUrl, authDomain, reportServiceSource)
      : aws.generateLearnerLogSQL(queryId, runnableUrl, authDomain, reportServiceSource);

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

  return {sqlOutput, portalUrl}
}

exports.lambdaHandler = async (event, context) => {
  try {
    const params = event.queryStringParameters || {};

    // get the report service source from the url
    const reportServiceSource = params.reportServiceSource;
    const debugSQL = params.debugSQL || false;
    const tokenServiceEnv = params.tokenServiceEnv;

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
    const {sqlOutput, portalUrl} = body.json.type === "users" ? await userReport(body, tokenServiceEnv, debugSQL) : await learnersReport(params, body, tokenServiceEnv, debugSQL, reportServiceSource);

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
