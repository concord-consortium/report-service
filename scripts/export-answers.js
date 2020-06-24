#!/usr/bin/env node

const BUCKET = "concordqa-report-data"
const DIRECTORY = "answers"

var AWS = require('aws-sdk');
const {Firestore} = require('@google-cloud/firestore');
const fs = require('fs');
const path = require('path');

const awsConfig = "./config.json"
if (!fs.existsSync(awsConfig)) {
  console.error("Missing config.json - please add your aws credentials to config.json like this: https://docs.aws.amazon.com/sdk-for-javascript/v2/developer-guide/loading-node-credentials-json-file.html");
  process.exit(1);
}
AWS.config.loadFromPath(awsConfig);

const s3 = new AWS.S3({apiVersion: '2006-03-01'})

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const outputPath = path.join(__dirname, "answers");
if (!fs.existsSync(outputPath)) {
  fs.mkdirSync(outputPath)
}

// Create a new client
const firestore = new Firestore();

const batchSize = 100;
let query = firestore.collection('sources/authoring.concord.org/answers');
let masterQuery = query.limit(batchSize)
  .orderBy('id')

let count = 0;
let lastDoc = null;
let batchCount = 0;
let batchIndex = 0;

function countBatch(query) {
  query.stream().on('data', (documentSnapshot) => {
    let data = documentSnapshot.data();
    // write file to s3
    s3.putObject({
      Bucket: BUCKET,
      Key: `${DIRECTORY}/${documentSnapshot.id}`,
      // ACL: 'public-read',
      Body: JSON.stringify(data),
      ContentType: 'application/json',
    }, function (err) {
      if (err) {
        console.error(`${documentSnapshot.id}: ${err.toString()}`)
      }
    });
    lastDoc = documentSnapshot;
    ++count;
    ++batchCount;
  // }).on('end', () => console.log('Done'));
  }).on('end', onEnd);
}

function onEnd() {
  if(batchCount == batchSize) {
    batchCount = 0;
    console.log(`Ended batch: ${batchIndex} last_id: ${lastDoc.id} ${JSON.stringify(process.memoryUsage())}`);
    ++batchIndex;
    // This might be bad because it might be growing the stack
    // but at least it isn't closing around anything extra
    countBatch(masterQuery.startAfter(lastDoc))
  } else {
    console.log(`Total count is ${count}`);
  }
}

countBatch(masterQuery);
