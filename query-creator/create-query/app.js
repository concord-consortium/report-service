const envVars = require("./steps/env-vars");
const request = require("./steps/request");
const firebase = require("./steps/firebase");
const aws = require("./steps/aws");
const tokenService = require("./steps/token-service");

exports.lambdaHandler = async (event, context) => {

  try {
    // ensure all the environment variables exist
    envVars.validate();

    // get the post body and validate the HMAC and format of the json payload
    const body = request.getBody(event);
    const json = request.validateJSON(body);
    const runnables = request.getRunnables(json);
    const user = json.user;

    // ensure create athena workgroup is created for the user and is added to token service
    const workgroup = await aws.ensureWorkgroup(user);
    await tokenService.addWorkgroup(workgroup);

    const debugSQL = [];

    for (let index = 0; index < runnables.length; index++) {
      const runnable = runnables[index];

      // get and denormalize the resource (activity or sequence) from Firebase
      const resource = await firebase.getResource(runnable, json.reportServiceSource);
      const denormalizedResource = firebase.denormalizeResource(resource);

      // upload the denormalized resource to s3 and tie it to the workgroup
      await aws.uploadDenormalizedResource(denormalizedResource, runnable, workgroup);

      // generate the sql for the query
      const sql = aws.generateSQL(runnable, resource, denormalizedResource)

      // create the athena query in the workgroup
      const query = await aws.createQuery(user, sql, workgroup)

      debugSQL.push(`${resource.id}:\n\n${sql}`);
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
