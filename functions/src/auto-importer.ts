import fs from "fs"
import path from "path"
import util from "util"
import crypto from "crypto";
import { performance } from 'perf_hooks';
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

const bucket = "concordqa-report-data"
const answerDirectory = "partitioned-answers"
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

interface S3SyncInfo {
  success: boolean;
  totalTime?: number;
  fileWriterTotalTime?: number;
  s3SendFileTotalTime?: number;
}

interface SyncData {
  updated: boolean;
  resource_url: string;
  last_answer_updated: firestore.Timestamp;
  need_sync?: firestore.Timestamp;
  did_sync?: firestore.Timestamp;
  start_sync?: firestore.Timestamp;
  info?: S3SyncInfo;
}

type PartialSyncData = Partial<SyncData>;

const getHash = (data: any) => {
  const hash = crypto.createHash('sha256');
  hash.update(JSON.stringify(data));
  return hash.digest('hex');
}

// syncSource is a wildcard in the Firestore path name
const answersPathAllSources = "sources/{syncSource}/answers"
const answersSyncPathAllSources = "sources/{syncSource}/answers_async"
const answersSyncPath = (syncSource: string) => `sources/${syncSource}/answers_async`

const getAnswersCollection = (syncSource: string) => admin.firestore().collection(`sources/${syncSource}/answers`);
const getAnswerSyncCollection = (syncSource: string) => admin.firestore().collection(answersSyncPath(syncSource));
// to monitor all answers_async documents across all sources, we need to use a collectionGroup, which requires
// adding a single field index exemption to the firestore setup
const getAnswerSyncAllSourcesCollection = () => admin.firestore().collectionGroup("answers_async");

const getSettings = () => {
  return admin.firestore()
    .collection("settings")
    .doc("autoImporter")
    .get()
    .then((doc) => (doc.data() as AutoImporterSettings) || defaultSettings)
    .catch(() => defaultSettings)
}

const addSyncDoc = (syncSource: string, runKey: string, resourceUrl: string) => {
  const syncDocRef = getAnswerSyncCollection(syncSource).doc(runKey);
  let syncDocData: SyncData = {
    updated: true,
    last_answer_updated: firestore.Timestamp.now(),
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

const deleteSyncDoc = (syncSource: string, runKey: string) => {
  return getAnswerSyncCollection(syncSource).doc(runKey).delete();
}

// gets AWS creds from firebase config.
const s3Client = () => new S3Client({
  region,
  credentials: {
    accessKeyId: functions.config().aws.key,
    secretAccessKey: functions.config().aws.secret_key,
  }
});

const syncToS3 = (answers: AnswerData[]): Promise<S3SyncInfo> => {
  const {run_key} = answers[0]
  const {filename, key} = parquetInfo(answerDirectory, answers[0]);
  const tmpFilePath = path.join("/tmp", filename);

  const deleteFile = async () => access(tmpFilePath).then(() => unlink(tmpFilePath)).catch(() => undefined);

  let resultsInfo: S3SyncInfo = {
    success: false
  };

  return new Promise(async (resolve, reject) => {
    try {
      const fileWriterStartTime = performance.now();

      // parquetjs can't write to buffers
      await deleteFile();
      const writer = await parquet.ParquetWriter.openFile(schema, tmpFilePath);
      for (const answer of answers) {
        answer.answer = JSON.stringify(answer.answer)
        await writer.appendRow(answer);
      }
      await writer.close();
      const fileWriterTotalTime = performance.now() - fileWriterStartTime;

      const body = await readFile(tmpFilePath)

      const putObjectCommand = new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: 'application/octet-stream'
      })

      const s3SendFileStartTime = performance.now();

      await s3Client().send(putObjectCommand)

      const s3SendFileTotalTime = performance.now() - s3SendFileStartTime;

      resultsInfo = {
        success: true,
        fileWriterTotalTime,
        s3SendFileTotalTime
      }
    } catch (err) {
      reject(`${run_key}: ${err.toString()}`);
    } finally {
      await deleteFile();
      resolve(resultsInfo);
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
  .document(`${answersPathAllSources}/{answerId}`) // NOTE: {answerId} is a wildcard passed to Firebase
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
            return addSyncDoc(context.params.syncSource, runKey, resourceUrl);
          }
        }

        return null;
      })
  });

export const monitorSyncDocCount = functions.pubsub.schedule(monitorSyncDocSchedule).onRun((context) => {
  return getSettings()
    .then(({ setNeedSync }) => {
      if (setNeedSync) {
        return getAnswerSyncAllSourcesCollection()
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
  .document(`${answersSyncPathAllSources}/{runKey}`) // NOTE: {answerId} is a wildcard passed to Firebase
  .onWrite((change, context) => {
    return getSettings()
      .then(({ sync }) => {
        if (sync && change.after.exists) {
          const data = change.after.data() as SyncData;

          const needSyncMoreRecentThanDidSync = data.need_sync && (!data.did_sync || (data.need_sync > data.did_sync));
          const needSyncMoreRecentThanStartSync = data.need_sync && (!data.start_sync || (data.need_sync > data.start_sync));

          if (data.need_sync && needSyncMoreRecentThanDidSync && needSyncMoreRecentThanStartSync) {
            const syncDocRef = getAnswerSyncCollection(context.params.syncSource).doc(context.params.runKey);

            syncDocRef.update({
              start_sync: firestore.Timestamp.now()
            } as PartialSyncData).catch(functions.logger.error)

            const syncToS3StartTime = performance.now();
            return getAnswersCollection(context.params.syncSource)
              .where("run_key", "==", context.params.runKey)
              .get()
              .then((querySnapshot) => {
                const answers: firestore.DocumentData[] = [];
                querySnapshot.forEach((doc) => {
                  answers.push(doc.data());
                });

                const setDidSync = (info: S3SyncInfo) => {
                  info.totalTime = performance.now() - syncToS3StartTime;
                  return syncDocRef.update({
                    did_sync: firestore.Timestamp.now(),
                    info
                  } as PartialSyncData)
                }

                if (answers.length) {
                  syncToS3(answers as AnswerData[])
                    .then(setDidSync)
                    .catch(functions.logger.error)
                } else {
                  // if the learner has no answers associated with this run, delete the doc
                  deleteFromS3(context.params.runKey, data.resource_url)
                    .catch(functions.logger.error);
                }
              });
          }
        }
        return null;
      });
});
