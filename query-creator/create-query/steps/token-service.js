const fetch = require("node-fetch");
const TokenServiceClient = require("@concord-consortium/token-service").TokenServiceClient;

const tokenServiceEnv = "staging";
const resourceType = "athenaWorkgroup";
const resourceTool = "researcher-report";

exports.findOrCreateResource = async (tokenServiceJwt, email, portalUrl) => {
  const client = new TokenServiceClient({ jwt: tokenServiceJwt, env: tokenServiceEnv, fetch});

  let resource;
  const escapedEmail = email.replace(/[^\w]/g,'-');

  const allResources = await client.listResources({
    type: resourceType,
    tool: resourceTool,
    name: escapedEmail,
    amOwner: "true"
  });

  if (allResources.length) {
    // there should be only one
    resource = allResources[0];
  } else {
    resource = await client.createResource({
      tool: resourceTool,
      type: resourceType,
      name: escapedEmail,
      description: `Report service workgroup for ${email} at ${portalUrl}`,
      accessRuleType: "user"
    });
  }

  return resource;
}

exports.addWorkgroup = async (workgroup) => {
  // TODO
  return Promise.resolve(undefined);
}