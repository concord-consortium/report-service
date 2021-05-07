#!/usr/bin/env node
const AWS = require('aws-sdk');
const {Firestore} = require('@google-cloud/firestore');
const fs = require('fs');
const path = require('path');
const util = require('util');

const BUCKET = process.argv[2];     // e.g. concordqa-report-data
const SOURCE =  process.argv[3];    // e.g. authoring.staging.concord.org

if (!BUCKET || !SOURCE) {
  console.error("Call script with `node export-answers.js [bucket-name] [source-id]`");
  return;
}

const DIRECTORY = "partitioned-answers"
const BATCH_SIZE = 100;

const access = util.promisify(fs.access);
const unlink = util.promisify(fs.unlink);
const readFile = util.promisify(fs.readFile);

const parquet = require('parquetjs');
const { parquetInfo, getSyncDocId, schema } = require('../functions/src/shared/s3-answers')

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

let query = firestore.collection(`sources/${SOURCE}/answers`);
let masterQuery = query.limit(BATCH_SIZE)
  .orderBy("resource_url")
  .orderBy("platform_id")
  .orderBy("resource_link_id")
  .orderBy("platform_user_id")
  .orderBy("run_key")
  .orderBy("id")

let count = 0;
let lastDoc = null;
let batchCount = 0;
let batchIndex = 0;
let lastUserRunKey = undefined;   // id for the a user's whole answer set, whether a run key or an hashed LTI combo
const answerHash = {};
const uploadPromises = {};

// set to true once all uploads have been created and the system is waiting for the uploads to finish
let waitingForUploadsToFinish = false;

function uploadAnswers(userRunKey) {
  if (!answerHash[userRunKey] || (answerHash[userRunKey].length === 0)) {
    return;
  }

  const answers = answerHash[userRunKey];
  const answer = answers[0];
  const info = parquetInfo(DIRECTORY, answer);
  if (!info) {
    return;
  }
  const {filename, key} = info;

  const tmpFilePath = path.join(outputPath, filename);

  if (uploadPromises[userRunKey]) {
    console.error("Already uploading", userRunKey)
    return;
  }

  const deleteTmpFile = async () => {
    return access(tmpFilePath).then(() => unlink(tmpFilePath)).catch(() => undefined);
  }

  uploadPromises[userRunKey] = new Promise(async (resolve) => {
    try {
      // parquetjs can't write to buffers
      await deleteTmpFile();
      var writer = await parquet.ParquetWriter.openFile(schema, tmpFilePath);
      for (let i = 0; i < answers.length; i++) {
        // clean up answer objects for parquet
        answers[i].answer = JSON.stringify(answers[i].answer)
        delete answers[i].report_state;
        if (typeof answers[i].version === "number") {
          answers[i].version = "" + answers[i].version;
        }

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
          console.error(`${userRunKey}: ${err.toString()}`)
        }
      }).promise();
    } catch (err) {
      console.error(err);
    } finally {
      await deleteTmpFile();
      delete answerHash[userRunKey];
    }

    // while running keep the upload promises object as small as possible by removing them from the hash
    // this is set to true once all the uploads have been created and the system is waiting for them to complete
    // via Promise.allSettled(...)
    if (!waitingForUploadsToFinish) {
      delete uploadPromises[userRunKey];
    }

    // always resolve
    resolve();
  });
}

function countBatch(query) {
  query.stream().on('data', (documentSnapshot) => {
    const answer = documentSnapshot.data();
    const userRunKey = getSyncDocId(answer);
    answerHash[userRunKey] = answerHash[userRunKey] || [];
    answerHash[userRunKey].push(answer);
    if (lastUserRunKey && (userRunKey !== lastUserRunKey)) {
      uploadAnswers(lastUserRunKey)
    }
    lastUserRunKey = userRunKey;
    lastDoc = documentSnapshot;
    ++count;
    ++batchCount;
  }).on('end', onEnd);
}

function finish() {
  console.log(`Finished: ${batchIndex}, uploads: ${Object.keys(uploadPromises).length}, memory: ${JSON.stringify(process.memoryUsage())}`);
  // flag that we are waiting for the uploads to finish - this changes the uploader to not remove upload promises from the hash it uses
  // to track them so that we can then use Promise.allSettled to wait for them to finish
  waitingForUploadsToFinish = true;
  uploadAnswers(lastUserRunKey);
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
