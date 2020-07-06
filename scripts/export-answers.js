#!/usr/bin/env node

const BUCKET = "concordqa-report-data"
const DIRECTORY = "partitioned-answers"
const BATCH_SIZE = 100;

var AWS = require('aws-sdk');
const {Firestore} = require('@google-cloud/firestore');
const fs = require('fs');
const path = require('path');

const zlib = require('zlib');
const util = require('util');
const gzip = util.promisify(zlib.gzip);

const access = util.promisify(fs.access);
const unlink = util.promisify(fs.unlink);
const readFile = util.promisify(fs.readFile);

const parquet = require('parquetjs');

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

const outputPath = path.join(__dirname, "uploads");
if (!fs.existsSync(outputPath)) {
  fs.mkdirSync(outputPath)
}

// Create a new client
const firestore = new Firestore();

let query = firestore.collection('sources/authoring.concord.org/answers');
let masterQuery = query.limit(BATCH_SIZE)
  .orderBy('run_key').orderBy("id")

let count = 0;
let lastDoc = null;
let batchCount = 0;
let batchIndex = 0;
let lastRunKey = undefined;
let waitingForUploadsToFinish = false;
const answerHash = {};
const uploadPromises = {};

const schema = new parquet.ParquetSchema({
  submitted: { type: 'BOOLEAN', optional: true },
  run_key: { type: 'UTF8' },
  platform_user_id: { type: 'UTF8', optional: true },
  id: { type: 'UTF8' },
  context_id: { type: 'UTF8', optional: true },
  class_info_url: { type: 'UTF8', optional: true },
  platform_id: { type: 'UTF8', optional: true },
  resource_link_id: { type: 'UTF8', optional: true },
  type: { type: 'UTF8' },
  question_id: { type: 'UTF8' },
  source_key: { type: 'UTF8' },
  question_type: { type: 'UTF8' },
  tool_user_id: { type: 'UTF8' },
  answer: { type: 'UTF8' },
  resource_url: { type: 'UTF8' },
  remote_endpoint: { type: 'UTF8', optional: true },
  created: { type: 'UTF8' },
  tool_id: { type: 'UTF8' },
  version: { type: 'UTF8' },
});

function uploadAnswers(runKey) {
  if (!answerHash[runKey] || (answerHash[runKey].length === 0)) {
    return;
  }

  const answers = answerHash[runKey];
  const answer = answers[0];
  const filename = path.join(outputPath, `${answer.run_key}.parquet`);
  const folder = answer.resource_url.replace(/[^a-z0-9]/g, "-");
  const key = `${DIRECTORY}/${folder}/${runKey}.parquet.gz`;

  if (uploadPromises[runKey]) {
    console.error("Already uploading", runKey)
    return;
  }

  const deleteFile = async () => {
    return access(filename).then(() => unlink(filename)).catch(() => undefined);
  }

  uploadPromises[runKey] = new Promise(async (resolve) => {
    try {
      // parquetjs can't write to buffers
      await deleteFile();
      var writer = await parquet.ParquetWriter.openFile(schema, filename);
      for (let i = 0; i < answers.length; i++) {
        answers[i].answer = JSON.stringify(answers[i].answer)
        await writer.appendRow(answers[i]);
      }
      await writer.close();

      const contents = await readFile(filename)
      const body = await gzip(contents)

      // write file to s3
      // console.log("uploading", key)
      await s3.putObject({
        Bucket: BUCKET,
        Key: key,
        Body: body,
        ContentType: 'application/json',
        ContentEncoding: "gzip"
      }, function (err) {
        if (err) {
          console.error(`${documentSnapshot.id}: ${err.toString()}`)
        }
      }).promise();
    } catch (err) {
      console.error(err);
    } finally {
      await deleteFile();
    }

    // while running keep the upload promises object as small as possible
    if (!waitingForUploadsToFinish) {
      delete uploadPromises[runKey];
    }

    // always resolve
    resolve();
  });

  // console.log("starting", key)
  // uploadPromises[runKey].then(() => console.log("done", key))
  Promise.resolve(uploadPromises[runKey])
}

function countBatch(query) {
  query.stream().on('data', (documentSnapshot) => {
    const answer = documentSnapshot.data();
    answerHash[answer.run_key] = answerHash[answer.run_key] || [];
    answerHash[answer.run_key].push(answer);
    if (lastRunKey && (answer.run_key !== lastRunKey)) {
      uploadAnswers(lastRunKey)
    }
    lastRunKey = answer.run_key;
    lastDoc = documentSnapshot;
    ++count;
    ++batchCount;
  // }).on('end', () => console.log('Done'));
  }).on('end', onEnd);
}

function finish() {
  console.log(`Finished: ${batchIndex}, uploads: ${Object.keys(uploadPromises).length}, memory: ${JSON.stringify(process.memoryUsage())}`);
  waitingForUploadsToFinish = true;
  uploadAnswers(lastRunKey);
  const promises = Object.values(uploadPromises);
  console.log(`Waiting for ${promises.length} uploads to finish...`);
  Promise.allSettled(promises).then(() => console.log("Done waiting!"))
}

function onEnd() {
  if (batchCount == BATCH_SIZE) {
    batchCount = 0;
    console.log(`Ended batch: ${batchIndex}, uploads: ${Object.keys(uploadPromises).length}, memory: ${JSON.stringify(process.memoryUsage())}`);
    ++batchIndex;
    // This might be bad because it might be growing the stack
    // but at least it isn't closing around anything extra
    countBatch(masterQuery.startAfter(lastDoc))
  } else {
    finish();
    console.log(`Total count is ${count}`);
  }
}

console.log("Starting query with batch size of", BATCH_SIZE);
countBatch(masterQuery);
