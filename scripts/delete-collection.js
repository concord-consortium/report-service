#!/usr/bin/env node
const { Firestore, doc, getDoc } = require('@google-cloud/firestore');
const fs = require('fs');
const { createTraverser } = require('@firecode/admin');


const SOURCE =  process.argv[2]; // e.g. activity-player.concord.org

if (!SOURCE) {
  console.error("Call script with `node export-answers.js [source-id]`");
  return;
}

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const deletedDocs = [];
const firestore = new Firestore();
const collection = firestore.collection(`sources/${SOURCE}`);
const traverser = createTraverser(collection, {
                                                batchSize: 500,
                                                maxConcurrentBatchCount: 20
                                              });

const deleteCollection = async () => {
  const { batchCount, docCount } = await traverser.traverse(async (batchDocs, batchIndex) => {
    const batchSize = batchDocs.length;
    await Promise.all (
      batchDocs.map(async (doc) => {
        deletedDocs.push(doc.ref.id);
        doc.ref.delete();
      })
    ).catch((e) => { console.log("Error: ", e); });
    console.log(`Batch ${batchIndex} done! We deleted ${batchSize} docs in this batch.`);
  });
  
  console.log(`Traversal done. We deleted ${docCount} docs in ${batchCount} batches.`);
  console.log("Deleted Docs", deletedDocs.length);
}

deleteCollection();
