const crypto = require('crypto');

exports.getBody = (event) => {
  if (event.body === null) {
    throw new Error("Missing post body in request")
  }
  return JSON.parse(event.body)

  /*

  // for testing
  return {
    allowDebug: 1,
    json: JSON.stringify({
      "type": "learners",
      "version": "1.1",
      "learners": [
        {"run_remote_endpoint": "https://example.com/1", "class_id": 1, "runnable":{"type": "activity", "id": 100}},
        {"run_remote_endpoint": "https://example.com/2", "class_id": 1, "runnable":{"type": "sequence", "id": 100}}
      ],
      "user": {
        "id": "https://example.com/users/1234",
        "email": "doug@example.com"
      },
      "reportServiceSource": "authoring.concord.org"
    }),
    signature: "4d59e0998f112485392d28b8033f41006cdb83d58c7eab715e8626bc3d866528"
  }
  */
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
    // console.log("digestBuffer", digestBuffer.toString())
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

  if (!json.reportServiceSource) {
    throw new Error("No user reportServiceSource found in json parameter")
  }

  return json;
}

exports.getRunnables = (json) => {
  const runnables = json.learners.map(l => l.runnable).filter(r => r !== undefined)
  if (runnables.length === 0) {
    throw new Error("No runnables found in request")
  }
  runnables.forEach(runnable => {
    runnable.remoteEndpoints = []
    json.learners.forEach(learner => {
      if (learner.runnable === runnable) {
        runnable.remoteEndpoints.push(learner.run_remote_endpoint)
      }
    })
  })
  return runnables;
}
