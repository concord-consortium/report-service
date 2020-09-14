import crypto from "crypto";
import * as functions from "firebase-functions";
import admin from "firebase-admin";

/*

1. per answer write create/update sync document per run_remote_endpoint (null, ignore) increment sync count
2. cron job looking at sync docs where count > 0 and setting flag to sync reset the count in a transaction
3. sync doc write looking for sync flag and then sync if true, then clear flag

*/

// 1. after an external write to the answer data. this increments needToSyncCount in the syncMetadata.
// 2. after the first call when needToSyncCount is incremented in syncMetadata.  this uploads the new data to s3 and then decrements needToSyncCount.
// 3. after the second call when needToSyncCount is decremented.  this is ignored.

const syncSource = "TODO: GET FROM ENVIRONMENT";

interface SyncData {
  // leaving out actual answer data here as it is an opaque blob for purposes on this code
  syncMetadata: {
    needToSyncCount: number;
    updatedAt: any;
    syncedAt: any;
  }
}

const getSyncData = (data: SyncData) => {
  const syncData = Object.assign({}, data);
  delete syncData.syncMetadata;
  return syncData;
}

const getSyncMetadata = (data: SyncData) => {
  return data.syncMetadata || {needToSyncCount: 0, updatedAt: null, syncedAt: null};
}

const getHash = (data: SyncData) => {
  const hash = crypto.createHash('sha256');
  hash.update(JSON.stringify(data));
  return hash.digest('hex');
}

const syncToS3 = (s3Path: string, data: SyncData) => {
  // TODO
  return Promise.resolve();
}

exports.syncToS3AfterAnswerWritten = functions.firestore
  .document(`sources/${syncSource}/answers/{answerId}`) // NOTE: {answerId} is correct (NOT ${answerId}) as it is a wildcard passed to Firebase
  .onWrite((change, context) => {
    if (!change.after.exists) {
      // answer has been deleted - what to do here?
      // trigger a sync
      return;
    }

    const newData: SyncData = change.after.data() as SyncData;
    const newSyncData = getSyncData(newData);
    const newSyncMetadata = getSyncMetadata(newData);
    const newHash = getHash(newSyncData);

    const oldData: SyncData = change.before.data() as SyncData;
    const oldSyncData = getSyncData(oldData);
    // const oldSyncMetadata = getSyncMetadata(oldData);
    const oldHash = getHash(oldSyncData);

    // a change outside the metadata has been made to the document
    if (newHash !== oldHash) {
      // write the syncMetadata, triggering another invocation of this function
      // which will move past this if check and upload the data to S3
      // NOTE: this could be set more than once if the answer is updated while
      // the S3 upload is in progress so we use increment(1) to retrigger another sync
      return change.after.ref.update({
        // this will leave syncedAt as is
        "syncMetadata.needToSyncCount": admin.firestore.FieldValue.increment(1),  // if needToSyncCount does not exist, firebase will set it to 1
        "syncMetadata.updatedAt": admin.firestore.FieldValue.serverTimestamp()
      });
    }

    // if we are here there has been a change in the syncMetadata after an update to the data
    if (newSyncMetadata.needToSyncCount > 0) {
      // sync to S3
      return new Promise((resolve, reject) => {
        const s3Path = TODO;

        // TODO: get curent data from firebase to sync

        // TODO: save hash and compare and if different do the upload, otherwise decrement sync count

        return syncToS3(s3Path, newSyncData)
          .then(() => {
            return change.after.ref.update({
                // this will leave updatedAt as is
                "syncMetadata.needToSyncCount": admin.firestore.FieldValue.increment(-1),
                "syncMetadata.syncedAt": admin.firestore.FieldValue.serverTimestamp()
              })
              .then(resolve)
              .catch(reject);
          })
          .catch(reject);
      });
    }

    // if we are here then we were triggered after the S3 upload so there is nothing to do
    return null;
  });

exports.monitorSyncToS3 = functions.pubsub.schedule("every 5 minutes").onRun((context) => {

  // get the monitoring settings - this will allow us to turn off syncing without a redeploy
  return admin.firestore()
    .collection("settings")
    .doc("monitorSyncToS3")
    .get()
    .then((doc) => {
      const settings = doc.data() || {};
      if (!settings.retrigger) {
        console.log("Aborting! Settings:", JSON.stringify(settings));
        return null;
      }
      const forceRetrigger = !!settings.forceRetrigger;
      const retriggerLimit = settings.retriggerLimit || 10;
      const retriggerAgeInSeconds = settings.retriggerAgeInSeconds || 300;
      console.log("Running! Settings:", JSON.stringify({
        forceRetrigger,
        retriggerLimit,
        retriggerAgeInSeconds
      }));

      // re-trigger the failed uploads up to a limit
      const retriggerTimeCutoff = new Date(Date.now() - retriggerAgeInSeconds);
      let query = admin.firestore()
        .collection(`sources/${syncSource}/answers`)
        .where("syncMetadata.needToSyncCount", ">", 0)
        .where("syncMetadata.syncedAt", "<", retriggerTimeCutoff);
      if (!forceRetrigger) {
        query = query.where("syncMetadata.needToSyncCount", "<", retriggerLimit)
      }

      return query
        .get()
        .then(function(querySnapshot) {
          querySnapshot.forEach(function(doc) {
            doc.ref.update({
              // this will leave the rest of syncMetadata as is
              "syncMetadata.needToSyncCount": firebase.firestore.FieldValue.increment(1)
            });
          });
        })
        .catch(function(error) {
          console.log("Error getting documents: ", error);
        });
    });
});