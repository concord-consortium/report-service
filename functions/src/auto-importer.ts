import fs from "fs"
import path from "path"
import util from "util"
import crypto from "crypto";
import * as functions from "firebase-functions";
import admin, { firestore } from "firebase-admin";

import { S3Client, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

const parquet = require('parquetjs');

const access = util.promisify(fs.access);
const unlink = util.promisify(fs.unlink);
const readFile = util.promisify(fs.readFile);

import { AnswerData, schema, parquetInfo } from "./shared/s3-answers"

/*

  TODO:

  1. Figure out how to get syncSource from the environment
  2. Figure out how to get AWS config from the environment

*/

/*

HOW THIS WORKS:

1. createSyncDocAfterAnswerWritten runs on every write of an answer.  If the answer changes or is deleted a "sync doc"
   is created or updated whose name is the run_key for the answer along with a boolean "updated".
2. monitorSyncDocCount runs as a cron job every few minutes to find all the docs with updated = true.  Each document that is
   found has a needs_sync field set to the current server time and has updated set to false.
3. syncToS3AfterSyncDocWritten runs on every write of a sync doc.  If the needs_sync field exists and either the doc has
   never synced before, or needs_sync > did_sync, it will gather up all the answers for that runKey and post them to
  s3 as a parquet file. If there are no answers, it will delete the parquet file. It will then set a did_sync timestamp
*/

const syncSource = "TODO: GET FROM ENVIRONMENT";
const bucket = "concordqa-report-data"
const answerDirectory = `${syncSource}/partitioned-answers`
const region = "us-east-1"

const monitorSyncDocSchedule = "every 4 minutes"

interface AutoImporterSettings {
  watchAnswers: boolean;
  setNeedSync: boolean;
  sync: boolean;
}

const defaultSettings: AutoImporterSettings = {
  watchAnswers: true,
  setNeedSync: true,
  sync: true,
}

interface SyncData {
  updated: boolean;
  resource_url: string;
  need_sync?: firestore.Timestamp;
  did_sync?: firestore.Timestamp;
}

type PartialSyncData = Partial<SyncData>;

const getHash = (data: any) => {
  const hash = crypto.createHash('sha256');
  hash.update(JSON.stringify(data));
  return hash.digest('hex');
}

const answersPath = () => `sources/${syncSource}/answers`
const answersSyncPath = () => `sources/${syncSource}/answers_async`

const getAnswerCollection = () => admin.firestore().collection(answersPath());
const getAnswerSyncCollection = () => admin.firestore().collection(answersSyncPath());

const getSettings = () => {
  return admin.firestore()
    .collection("settings")
    .doc("autoImporter")
    .get()
    .then((doc) => (doc.data() as AutoImporterSettings) || defaultSettings)
    .catch(() => defaultSettings)
}

const addSyncDoc = (runKey: string, resourceUrl: string) => {
  const syncDocRef = getAnswerSyncCollection().doc(runKey);
  let syncDocData: SyncData = {
    updated: true,
    resource_url: resourceUrl
  };

  return admin.firestore().runTransaction((transaction) => {
    return transaction.get(syncDocRef).then((doc) => {
      if (doc.exists) {
        // add the existing field values with the new field values overwriting them
        const existingSyncDocData = doc.data() as SyncData
        syncDocData = {...existingSyncDocData, ...syncDocData}
        return transaction.update(syncDocRef, syncDocData);
      } else {
        return transaction.set(syncDocRef, syncDocData);
      }
    })
  })
};

// gets AWS creds from firebase config.
const s3Client = () => new S3Client({
  region,
  credentials: {
    accessKeyId: functions.config().aws.key,
    secretAccessKey: functions.config().aws.secret_key,
  }
});

const syncToS3 = (answers: AnswerData[]) => {
  const {run_key} = answers[0]
  const {filename, key} = parquetInfo(answerDirectory, answers[0]);
  const tmpFilePath = path.join("/tmp", filename);

  const deleteFile = async () => access(tmpFilePath).then(() => unlink(tmpFilePath)).catch(() => undefined);

  return new Promise(async (resolve, reject) => {
    try {
      // parquetjs can't write to buffers
      await deleteFile();
      const writer = await parquet.ParquetWriter.openFile(schema, tmpFilePath);
      for (const answer of answers) {
        answer.answer = JSON.stringify(answer.answer)
        await writer.appendRow(answer);
      }
      await writer.close();

      const body = await readFile(tmpFilePath)

      const putObjectCommand = new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: 'application/octet-stream'
      })

      await s3Client().send(putObjectCommand)

    } catch (err) {
      reject(`${run_key}: ${err.toString()}`);
    } finally {
      await deleteFile();
      resolve(true);
    }
  });
}

const deleteFromS3 = (runKey: string, resourceUrl: string) => {
  const {key} = parquetInfo(answerDirectory, null, runKey, resourceUrl);
  const deleteObjectCommand = new DeleteObjectCommand({
    Bucket: bucket,
    Key: key
  })
  return s3Client().send(deleteObjectCommand)
}

export const createSyncDocAfterAnswerWritten = functions.firestore
  .document(`${answersPath()}/{answerId}`) // NOTE: {answerId} is correct (NOT ${answerId}) as it is a wildcard passed to Firebase
  .onWrite((change, context) => {
    return getSettings()
      .then(({ watchAnswers }) => {
        if (watchAnswers) {
          // need to get the before data in case answer was deleted
          const runKey = change.before.data()?.run_key;
          // likewise, if the answer was deleted, we need to record where it used to be, to potentially delete the doc
          const resourceUrl = change.before.data()?.resource_url;


          if (!runKey) {
            return null;
          }

          const beforeHash = getHash(change.before.data());
          const afterHash = getHash(change.after.data());

          if (afterHash !== beforeHash) {
            return addSyncDoc(runKey, resourceUrl);
          }
        }

        return null;
      })
  });

export const monitorSyncDocCount = functions.pubsub.schedule(monitorSyncDocSchedule).onRun((context) => {
  return getSettings()
    .then(({ setNeedSync }) => {
      if (setNeedSync) {
        return getAnswerSyncCollection()
                  .where("updated", "==", true)
                  .get()
                  .then((querySnapshot) => {
                    const promises: Promise<FirebaseFirestore.WriteResult>[] = [];
                    querySnapshot.forEach((doc) => {
                      // use a timestamp instead of a boolean for sync so that we trigger a write
                      promises.push(doc.ref.update({
                        need_sync: firestore.Timestamp.now(),
                        updated: false
                      } as PartialSyncData));
                    });
                    return Promise.all(promises);
                  });
      }
      return null;
    });
});

export const syncToS3AfterSyncDocWritten = functions.firestore
  .document(`${answersSyncPath()}/{runKey}`) // NOTE: {answerId} is correct (NOT ${answerId}) as it is a wildcard passed to Firebase
  .onWrite((change, context) => {
    return getSettings()
      .then(({ sync }) => {
        if (sync && change.after.exists) {
          const data = change.after.data() as SyncData;

          if (data.need_sync && (!data.did_sync || (data.need_sync > data.did_sync))) {
            return getAnswerCollection()
              .where("run_key", "==", context.params.runKey)
              .get()
              .then((querySnapshot) => {
                const answers: firestore.DocumentData[] = [];
                querySnapshot.forEach((doc) => {
                  answers.push(doc.data());
                });

                const syncDocRef = getAnswerSyncCollection().doc(context.params.runKey);
                const setDidSync = () => syncDocRef.update({did_sync: firestore.Timestamp.now()} as PartialSyncData)

                if (answers.length) {
                  syncToS3(answers as AnswerData[])
                    .then(setDidSync)
                    .catch(functions.logger.error)
                } else {
                  // if the learner has no answers associated with this run, delete the doc
                  deleteFromS3(context.params.runKey, data.resource_url);
                }
              });
          }
        }
        return null;
      });
});
