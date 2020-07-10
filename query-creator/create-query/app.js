const { v4: uuidv4 } = require('uuid');

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
    if (!reportServiceSource) {
      throw new Error("Missing reportServiceSource in the report url");
    }

    // see if we are in demo mode which uses built in request bodies and firebase data
    const demo = !!params.demo;

    // ensure all the environment variables exist
    envVars.validate();

    // get the post body and validate the HMAC and format of the json payload
    const body = request.getBody(event, demo);
    const json = request.validateJSON(body);
    const runnables = request.getRunnables(json);
    const user = json.user;

    // ensure create athena workgroup is created for the user and is added to token service
    const workgroup = await aws.ensureWorkgroup(user);
    await tokenService.addWorkgroup(workgroup);

    const debugSQL = [];

    for (let index = 0; index < runnables.length; index++) {
      const runnable = runnables[index];

      // single id that ties together the uploaded files to s3 and the Athena query
      const queryId = uuidv4()

      // upload the learner data
      await aws.uploadLearnerData(queryId, runnable.learners, workgroup);

      // get and denormalize the resource (activity or sequence) from Firebase
      const resource = await firebase.getResource(runnable, reportServiceSource, demo);
      const denormalizedResource = firebase.denormalizeResource(resource);

      // upload the denormalized resource to s3 and tie it to the workgroup
      await aws.uploadDenormalizedResource(queryId, denormalizedResource, workgroup);

      // generate the sql for the query
      const sql = aws.generateSQL(queryId, runnable, resource, denormalizedResource)

      // create the athena query in the workgroup
      const query = await aws.createQuery(queryId, user, sql, workgroup)

      debugSQL.push(`-- ${resource.id}\n\n${sql}`);
    }

    // TODO: redirect the user to the result loader
    return {
      statusCode: 200,
      body: debugSQL.join("\n\n------\n\n")
    }
  } catch (err) {
    console.log(err);
    return {
      statusCode: 500,
      body: err.toString()
    }
  }
};
