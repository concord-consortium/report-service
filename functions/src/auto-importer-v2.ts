import crypto from "crypto";
import * as functions from "firebase-functions";
import admin from "firebase-admin";

/*

1. per answer write create/update sync document per run_key (null, ignore) increment sync count
2. cron job looking at sync docs where count > 0 and setting flag to sync reset the count in a transaction
3. sync doc write looking for sync flag and then sync if true, then clear flag

*/

const syncSource = "TODO: GET FROM ENVIRONMENT";

interface AnswerData {
  // leaving out everything but the run_key which is what we care about
  run_key?: string;
}

interface SyncData {
  run_key: string;
  count: number | FirebaseFirestore.FieldValue;
  remove?: boolean;
  sync?: boolean;
}

const getHash = (data: any) => {
  const hash = crypto.createHash('sha256');
  hash.update(JSON.stringify(data));
  return hash.digest('hex');
}

const getSyncCollection = () => {
  return admin.firestore().collection(`sources/${syncSource}/sync_answers`);
}

const addSyncDoc = (data: AnswerData, options: {remove: boolean} = {remove: false}) => {
  const {run_key} = data;
  if (run_key) {
    const docRef = getSyncCollection().doc(run_key);
    const docData: SyncData = {
      run_key,
      count: admin.firestore.FieldValue.increment(1)
    };
    if (options.remove) {
      docData.remove = true;
    }

    return admin.firestore().runTransaction((transaction) => {
      return transaction.get(docRef).then((doc) => {
        if (doc.exists) {
          return docRef.update(docData);
        } else {
          return docRef.set(docData);
        }
      })
    })
  }

  return null;
};

/*
const syncToS3 = (s3Path: string, data: SyncData) => {
  // TODO
  return Promise.resolve();
}
*/

exports.createSyncDocAfterAnswerWritten = functions.firestore
  .document(`sources/${syncSource}/answers/{answerId}`) // NOTE: {answerId} is correct (NOT ${answerId}) as it is a wildcard passed to Firebase
  .onWrite((change, context) => {
    const oldData = change.before.data() as AnswerData;
    const oldHash = getHash(oldData);

    if (!change.after.exists) {
      // answer has been deleted - mark the sync doc as removed
      return addSyncDoc(oldData, {remove: true});
    }

    const newData = change.after.data() as AnswerData;
    const newHash = getHash(newData);

    if (newHash !== oldHash) {
      return addSyncDoc(newData);
    }

    return null;
  });

exports.monitorSyncDocCount = functions.pubsub.schedule("every 4 minutes").onRun((context) => {
  return getSyncCollection()
          .where("count", ">", 0)
          .get()
          .then((querySnapshot) => {
            const promises: Promise<FirebaseFirestore.WriteResult>[] = [];
            querySnapshot.forEach((doc) => {
              promises.push(doc.ref.update({
                sync: true,
                count: 0
              }));
            });
            return Promise.all(promises);
          });
});

/*

exports.monitorSyncDocSync = functions.pubsub.schedule("every 5 minutes").onRun((context) => {

  // get the monitoring settings - this will allow us to turn off syncing without a redeploy
  return admin.firestore()
    .collection("settings")
    .doc("monitorSyncAnswersToS3")
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
      let query = getSyncCollection()
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

*/
