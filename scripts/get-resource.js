#!/usr/bin/env node
const fs = require("fs");
const {Firestore} = require('@google-cloud/firestore');

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const [node, script, ...args] = process.argv;
if (args.length !== 1) {
  console.error("Usage: get-resource.js <document-name>")
  process.exit(1)
}
const id = args[0]

const firestore = new Firestore();
const ref = firestore.doc(`sources/authoring.staging.concord.org/resources/${id}`);

ref.get().then(snapshot => {
  if (snapshot.exists) {
    console.log(JSON.stringify(snapshot.data(), null, 2))
  } else {
    console.error("No resource found with that id!")
  }
})
