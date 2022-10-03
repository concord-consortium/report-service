#!/usr/bin/env node
const { Firestore, doc, getDoc } = require('@google-cloud/firestore');
const fs = require('fs');
const { createTraverser } = require('@firecode/admin');

/*
This script can be used to get a count of documents in a Firestore collection.
It uses https://github.com/kafkas/firecode to efficiently traverse collections.
It's currently configured to count sync docs that fall within a specified date 
range, but could be modified to count other documents that meet other criteria.
*/

const SOURCE =  process.argv[2];    // e.g. activity-player.concord.org
const START_DATE = process.argv[3]; // e.g. 2022-09-26
const END_DATE = process.argv[4]; // e.g. 2022-09-27
const MAX_DOC_COUNT = process.argv[5] ? parseInt(process.argv[5], 10) : Infinity; // e.g. 100

if (!SOURCE) {
  console.error("Call script with `node export-answers.js [source-id] [start-date] [end-date]`");
  return;
}

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const isInDateRange = (answerUpdated) => {
  const startDate = new Date(START_DATE).valueOf();
  const endDate = new Date(END_DATE).valueOf();
  const answerDate = new Date(answerUpdated).valueOf();
  return answerDate >= startDate && answerDate <= endDate;
}

const targetDocs = [];
const firestore = new Firestore();
const collection = firestore.collection(`sources/${SOURCE}/answers_async`)
                            // .where("last_answer_updated", ">=", new Date("2022-08-01"))
                            .where("updated", "==", false);
const traverser = createTraverser(collection, {
                                                batchSize: 500,
                                                maxConcurrentBatchCount: 20,
                                                maxDocCount: MAX_DOC_COUNT
                                              });

const countSyncDocs = async () => {
  const { batchCount, docCount } = await traverser.traverse(async (batchDocs, batchIndex) => {
    const batchSize = batchDocs.length;
    await Promise.all (
      batchDocs.map(async (doc) => {
        const data = doc.data();
        const lastAnswerIsInDateRange = isInDateRange(data.last_answer_updated.toDate().toDateString());
        if (lastAnswerIsInDateRange) {
          doc.ref.update({ updated: true });
          targetDocs.push(doc.ref.id);
        }
      })
    ).catch((e) => { console.log("Error: ", e); });
    console.log(`Batch ${batchIndex} done! We checked ${batchSize} docs in this batch.`);
  });
  
  console.log(`Traversal done. We checked ${docCount} docs in ${batchCount} batches.`);
  console.log("Matching doc count:", targetDocs.length);
}

countSyncDocs();
