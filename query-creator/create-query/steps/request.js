const crypto = require('crypto');
const queryString = require('query-string');

exports.getBody = (event, demo) => {
  if (demo) {
    return {
      allowDebug: 1,
      json: JSON.stringify({
        "type": "learners",
        "version": "1.1",
        "learners": [
          {
            "run_remote_endpoint": "https://learn.staging.concord.org/dataservice/external_activity_data/54e0af43-e700-446e-b9db-c64b21c2aeab",
            "class_id": 33,
            "runnable_url": "https://authoring.staging.concord.org/sequences/120"
          },
          {
            "run_remote_endpoint": "https://learn.staging.concord.org/dataservice/external_activity_data/2a2945e1-399f-4574-ac5c-cdeec1c408bd",
            "class_id": 33,
            "runnable_url": "https://authoring.staging.concord.org/sequences/120"
          },
          {
            "run_remote_endpoint": "https://learn.staging.concord.org/dataservice/external_activity_data/8fbbf080-a785-46c0-b812-d2502715e125",
            "class_id": 33,
            "runnable_url": "https://authoring.staging.concord.org/sequences/120"
          },
          {
            "run_remote_endpoint": "https://learn.staging.concord.org/dataservice/external_activity_data/af3b2317-039f-4543-82ff-4e312a1ee0f9",
            "class_id": 33,
            "runnable_url": "https://authoring.staging.concord.org/sequences/120"
          },
          {
            "run_remote_endpoint": "https://learn.staging.concord.org/dataservice/external_activity_data/7f7139f9-dced-43f6-93bd-20f5fbf2c642",
            "class_id": 33,
            "runnable_url": "https://authoring.staging.concord.org/sequences/120"
          },
        ],
        "user": {
          "id": "https://example.com/users/1234",
          "email": "user@example.com"
        }
      }),
      signature: "4d86176489615a0825fbddfead23b6cf4ed75522147ec4e46f0f8d606b7d54d6"
    }
  }

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

  const signature = body.signature;
  if (!signature) {
    throw new Error("Missing signature body parameter");
  }

  const hmac = crypto.createHmac('sha256', process.env.JWT_HMAC_SECRET);
  hmac.update(json);
  const signatureBuffer = new Buffer(signature);
  const digestBuffer = new Buffer(hmac.digest('hex'));

  if ((signatureBuffer.length !== digestBuffer.length) || !crypto.timingSafeEqual(signatureBuffer, digestBuffer)) {
    console.log("digestBuffer", digestBuffer.toString())
    throw new Error("Invalid signature for json parameter");
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
