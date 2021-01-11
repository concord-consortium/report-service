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

const access = util.promisify(fs.access);
const unlink = util.promisify(fs.unlink);
const readFile = util.promisify(fs.readFile);

const parquet = require('parquetjs');
const { parquetInfo, schema } = require('../functions/src/shared/s3-answers')

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

let query = firestore.collection('sources/authoring.staging.concord.org/answers');
let masterQuery = query.limit(BATCH_SIZE)
  .orderBy('run_key').orderBy("id")

let count = 0;
let lastDoc = null;
let batchCount = 0;
let batchIndex = 0;
let lastRunKey = undefined;
const answerHash = {};
const uploadPromises = {};

// set to true once all uploads have been created and the system is waiting for the uploads to finish
let waitingForUploadsToFinish = false;

function uploadAnswers(runKey) {
  if (!answerHash[runKey] || (answerHash[runKey].length === 0)) {
    return;
  }

  const answers = answerHash[runKey];
  const answer = answers[0];
  const {filename, key} = parquetInfo(answer, DIRECTORY);
  const tmpFilePath = path.join(outputPath, filename);

  if (uploadPromises[runKey]) {
    console.error("Already uploading", runKey)
    return;
  }

  const deleteTmpFile = async () => {
    return access(tmpFilePath).then(() => unlink(tmpFilePath)).catch(() => undefined);
  }

  uploadPromises[runKey] = new Promise(async (resolve) => {
    try {
      // parquetjs can't write to buffers
      await deleteTmpFile();
      var writer = await parquet.ParquetWriter.openFile(schema, tmpFilePath);
      for (let i = 0; i < answers.length; i++) {
        answers[i].answer = JSON.stringify(answers[i].answer)
        await writer.appendRow(answers[i]);
      }
      await writer.close();

      const body = await readFile(tmpFilePath)

      // write file to s3
      // console.log("uploading", key)
      await s3.putObject({
        Bucket: BUCKET,
        Key: key,
        Body: body,
        ContentType: 'application/octet-stream'
      }, function (err) {
        if (err) {
          console.error(`${runKey}: ${err.toString()}`)
        }
      }).promise();
    } catch (err) {
      console.error(err);
    } finally {
      await deleteTmpFile();
      delete answerHash[runKey];
    }

    // while running keep the upload promises object as small as possible by removing them from the hash
    // this is set to true once all the uploads have been created and the system is waiting for them to complete
    // via Promise.allSettled(...)
    if (!waitingForUploadsToFinish) {
      delete uploadPromises[runKey];
    }

    // always resolve
    resolve();
  });
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
  // flag that we are waiting for the uploads to finish - this changes the uploader to not remove upload promises from the hash it uses
  // to track them so that we can then use Promise.allSettled to wait for them to finish
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
