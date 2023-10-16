const axios = require("axios");
const queryString = require('query-string');

exports.getBody = (event) => {

  if (event.body === null) {
    throw new Error("Missing post body in request")
  }
  return queryString.parse(event.body)
}

/**
 * Throws errors if the request body is malformed, and parses the json property in-place.
 */
exports.validateRequestBody = (body) => {
  if (!body.jwt && !body.portal_token) {
    throw new Error("Missing jwt or portal_token body parameter");
  }
  let json = body.json;
  if (!json) {
    throw new Error("Missing json body parameter");
  }

  try {
    json = JSON.parse(json);
  } catch (e) {
    throw new Error("Unable to parse json parameter");
  }

  if (json.type === "users" && json.version !== "1.0") {
    throw new Error(`Request version is ${json.version}, 1.0 required for user report`);
  }
  else if (json.type === "learners" && json.version !== "2") {
    throw new Error(`Request version is ${json.version}, 2 required for learners report`);
  }

  body.json = json;
}

exports.getLearnerDataWithJwt = (learnersApiUrl, queryParams, jwt) => {
  return axios.post(learnersApiUrl, queryParams,
    {
      headers: {
        "Authorization": `Bearer/JWT ${jwt}`
      }
    }
  ).then((response) => {
    return response.data;
  }, (error) => {
    throw error;
  });
}

/**
 * Returns [{runnableUrl, learners[]}, ...]
 */
exports.getLearnersPerRunnable = (learners) => {
  // get unique (non null/empty/undefined) runnable urls
  const runnableUrls = learners
    .map(l => l.runnable_url)
    .filter(runnableUrl => !!runnableUrl)
    .filter((runnableUrl, index, self) => self.indexOf(runnableUrl) === index)
  if (runnableUrls.length === 0) {
    throw new Error("No runnable urls found in request")
  }
  return runnableUrls.map(runnableUrl => {
    const runnable = {
      runnableUrl,
      learners: []
    }
    learners.forEach(learner => {
      if (learner.runnable_url === runnableUrl) {
        runnable.learners.push(learner)
      }
    })
    return runnable
  })
}

exports.getTokenServiceJwt = async (portalUrl, jwt) => {
  const authHeader = {
    "Authorization": `Bearer/JWT ${jwt}`
  };
  const firebaseTokenGettingUrl = `${portalUrl}/api/v1/jwt/firebase?firebase_app=token-service`;
  return axios.get(firebaseTokenGettingUrl, { headers: authHeader })
    .then(response => response.data.token)
};
