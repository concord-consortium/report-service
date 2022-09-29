#!/usr/bin/env node
const { Firestore, doc, getDoc } = require('@google-cloud/firestore');
const fs = require('fs');
const { createTraverser } = require('@firecode/admin');


const SOURCE =  process.argv[2];    // e.g. activity-player.concord.org
const START_DATE = process.argv[3]; // 2022-09-26
const END_DATE = process.argv[4]; // 2022-09-27
// let startDateRegex;
// if (START_DATE) {
//   startDateRegex = new RegExp(START_DATE);
// }

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

const unprocessedDocs = [];
const firestore = new Firestore();
const collection = firestore.collection(`sources/${SOURCE}/answers_async`)
                            .where("last_answer_updated", ">=", new Date("2022-09-01"));
const traverser = createTraverser(collection, {
                                                batchSize: 500,
                                                maxConcurrentBatchCount: 20
                                              });

const countSyncDocs = async () => {
  const { batchCount, docCount } = await traverser.traverse(async (batchDocs, batchIndex) => {
    const batchSize = batchDocs.length;
    await Promise.all (
      batchDocs.map(async (doc) => {
        const data = doc.data();
        const lastAnswerIsInDateRange = isInDateRange(data.last_answer_updated.toDate().toDateString());
        const needSyncMoreRecentThanDidSync = data.need_sync && (!data.did_sync || (data.need_sync > data.did_sync));
        const needSyncMoreRecentThanStartSync = data.need_sync && (!data.start_sync || (data.need_sync > data.start_sync));
        // if (
        //      // lastAnswerIsInDateRange &&
        //     //  data.need_sync && 
        //     //  (needSyncMoreRecentThanDidSync || needSyncMoreRecentThanStartSync)
        //    ) {
        unprocessedDocs.push(doc.ref.id);
        // }
      })
    );
    console.log(`Batch ${batchIndex} done! We checked ${batchSize} sync docs in this batch.`);
  });
  
  console.log(`Traversal done. We checked ${docCount} sync docs in ${batchCount} batches.`);
  console.log("Matching Docs", unprocessedDocs.length);
}

countSyncDocs();
