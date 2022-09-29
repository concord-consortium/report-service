#!/usr/bin/env node
const { Firestore, doc, getDoc } = require('@google-cloud/firestore');
const fs = require('fs');
const { createTraverser } = require('@firecode/admin');


const SOURCE =  process.argv[2];    // e.g. activity-player.concord.org
const MAX_DOC_COUNT = parseInt(process.argv[3], 10); // e.g. 100
const START_DATE = process.argv[4]; // e.g. 2022-09-26
const END_DATE = process.argv[5]; // e.g. 2022-09-27

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
        // const needSyncMoreRecentThanDidSync = data.need_sync && (!data.did_sync || (data.need_sync > data.did_sync));
        // const needSyncMoreRecentThanStartSync = data.need_sync && (!data.start_sync || (data.need_sync > data.start_sync));
        if (
          lastAnswerIsInDateRange
        ) {
          doc.ref.update({ updated: true });
          targetDocs.push(doc.ref.id);
        }
      })
    );
    console.log(`Batch ${batchIndex} done! We checked ${batchSize} sync docs in this batch.`);
  });
  
  console.log(`Traversal done. We checked ${docCount} sync docs in ${batchCount} batches.`);
  console.log("Matching Docs", targetDocs.length);
}

countSyncDocs();
