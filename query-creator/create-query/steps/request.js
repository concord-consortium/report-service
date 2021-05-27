const crypto = require('crypto');
const queryString = require('query-string');

exports.getBody = (event) => {

  if (event.body === null) {
    throw new Error("Missing post body in request")
  }
  return queryString.parse(event.body)
}

exports.validateJSON = (body) => {
  let json = body.json;
  if (!json) {
    throw new Error("Missing json body parameter");
  }

  try {
    json = JSON.parse(json);
  } catch (e) {
    throw new Error("Unable to parse json parameter");
  }

  if (json.version !== "1.1") {
    throw new Error(`Request version is ${json.version}, 1.1 required`);
  }

  if (!json.learners) {
    throw new Error("No learners found in json parameter")
  }

  if (!json.user) {
    throw new Error("No user info found in json parameter")
  }
  if (!json.user.id) {
    throw new Error("No user id found in json parameter")
  }
  if (!json.user.email) {
    throw new Error("No user email found in json parameter")
  }

  return json;
}

exports.getRunnables = (json) => {
  // get unique runnable urls
  const runnableUrls = json.learners
    .map(l => l.runnable_url)
    .filter(runnableUrl => runnableUrl !== undefined)
    .filter((runnableUrl, index, self) => self.indexOf(runnableUrl) === index)
  if (runnableUrls.length === 0) {
    throw new Error("No runnable urls found in request")
  }
  return runnableUrls.map(runnableUrl => {
    const runnable = {
      url: runnableUrl,
      learners: []
    }
    json.learners.forEach(learner => {
      if (learner.runnable_url === runnableUrl) {
        runnable.learners.push(learner)
      }
    })
    return runnable
  })
}
