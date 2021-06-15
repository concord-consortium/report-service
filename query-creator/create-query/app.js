const envVars = require("./steps/env-vars");
const request = require("./steps/request");
const firebase = require("./steps/firebase");
const aws = require("./steps/aws");
const tokenService = require("./steps/token-service");

exports.lambdaHandler = async (event, context) => {

  try {
    const params = event.queryStringParameters || {};

    // get the report service source from the url
    const reportServiceSource = params.reportServiceSource;
    const debugSQL = params.debugSQL || false;

    if (!reportServiceSource) {
      throw new Error("Missing reportServiceSource in the report url");
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

    const tokenServiceJwt = await request.getTokenServiceJwt(portalUrl, jwt);

    const resource = await tokenService.findOrCreateResource(tokenServiceJwt, email, portalUrl);
    const workgroupName = await aws.ensureWorkgroup(resource, user);

    const queryIdsPerRunnable = await aws.fetchAndUploadLearnerData(jwt, query, learnersApiUrl);

    const sqlOutput = [];

    for (const runnableUrl in queryIdsPerRunnable) {
      const queryId = queryIdsPerRunnable[runnableUrl];

      // get and denormalize the resource (activity or sequence) from Firebase
      const resource = await firebase.getResource(runnableUrl, reportServiceSource);
      const denormalizedResource = firebase.denormalizeResource(resource);

      // upload the denormalized resource to s3 and tie it to the workgroup
      await aws.uploadDenormalizedResource(queryId, denormalizedResource);

      // generate the sql for the query
      const sql = aws.generateSQL(queryId, resource, denormalizedResource)

      if (debugSQL) {
        sqlOutput.push(`-- ${resource.id}\n\n${sql}`);
      } else {
        // create the athena query in the workgroup
        await aws.startQueryExecution(sql, workgroupName)
      }
    }

    const message = sqlOutput.length ? sqlOutput.join("\n\n------\n\n") : "Success"

    // TODO: redirect the user to the result loader
    return {
      statusCode: 200,
      body: message
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
