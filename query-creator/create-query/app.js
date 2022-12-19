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

const convertLaraMatchedActivityUrl = (matches) => matches[1] === "sequences" ? `sequence: ${matches[2]}` : `activity: ${matches[2]}`;

const prettySQL = (sql) => {
  return sql
    .split("\n")
    .map(line => line.trim())
    .map(line => {
      if (line.length === 0 || line[0].match(/[A-Z]/) || line[0].match(/\s/)) {
        return line
      }
      return "  " + line
    })
    .join("\n")
}

const userReport = async (body, tokenServiceEnv, debugSQL) => {
  const { json, portal_token } = body;
  const { user, portal_url, domain, users, runnables, start_date, end_date } = json;

  const portalUrl = trimTrailingSlash(portal_url);

  const workgroupName = await ensureWorkgroup(portalUrl, portal_token, tokenServiceEnv, user.email);

  const usernames = users.map(u => `${u.id}@${domain}`);
  const activities = [];
  runnables.forEach(r => {
    const url = new URL(r.url);

    // pre-LARA 2 activities non-AP activities logged the activity as type: ID
    const pathMatch = url.pathname.match(/\/(sequences|activities)\/(\d+)/);
    if (pathMatch) {
      activities.push(convertLaraMatchedActivityUrl(pathMatch));
    } else {
      // AP logs the url passed in the sequence or activity param to AP.  Since we can't be sure of the domain of
      // the AP we verify that the param looks like an url to the sequence or activity structure api endpoint.
      // We also add the older pre-LARA 2 activity/sequence: ID as this may be an activity that was migrated
      // from LARA and has logs in the older format.
      const sequenceOrActivityParam = url.searchParams.get("sequence") || url.searchParams.get("activity");
      const paramMatch = sequenceOrActivityParam && sequenceOrActivityParam.match(/(sequences|activities)\/(\d+)\.json/);
      if (paramMatch) {
        activities.push(sequenceOrActivityParam);
        activities.push(convertLaraMatchedActivityUrl(paramMatch));
      } else {
        activities.push(r.url);
      }
    }
  });

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

  const doLearnerAnswerReporting = async () => {
    const runnableInfo = {};

    for (const runnableUrl in queryIdsPerRunnable) {
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

      runnableInfo[queryId] = {runnableUrl, resource, denormalizedResource};
    }

    // generate the sql for the query
    const sql = aws.generateSQL(runnableInfo, usageReport, authDomain, reportServiceSource);

    if (debugSQL) {
      sqlOutput.push(sql);
    } else {
      // create the athena query in the workgroup
      await aws.startQueryExecution(sql, workgroupName)
    }
  }

  const doLearnerLogReporting= async () => {
    // generate the sql for the query
    const sql = narrowLearners
      ? aws.generateNarrowLogSQL(queryIdsPerRunnable, authDomain, reportServiceSource)
      : aws.generateLearnerLogSQL(queryIdsPerRunnable, authDomain, reportServiceSource);

    if (debugSQL) {
      sqlOutput.push(sql);
    } else {
      // create the athena query in the workgroup
      await aws.startQueryExecution(sql, workgroupName)
    }
  };

  if (useLogs) {
    await doLearnerLogReporting();
  }
  else {
    await doLearnerAnswerReporting();
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
    const {sqlOutput, portalUrl} = body.json.type === "users"
      ? await userReport(body, tokenServiceEnv, debugSQL)
      : await learnersReport(params, body, tokenServiceEnv, debugSQL, reportServiceSource);

    let message = prettySQL(sqlOutput.length ? sqlOutput.join("\n\n------\n\n") : "Success")

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
