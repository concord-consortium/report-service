import fs from "fs"
import path from "path"
import util from "util"
import https from "https"
import crypto from "crypto";
import { performance } from 'perf_hooks';
import * as functions from "firebase-functions";
import admin, { firestore } from "firebase-admin";
import axios from "axios";

import { S3Client, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

const parquet = require('parquetjs');

const access = util.promisify(fs.access);
const unlink = util.promisify(fs.unlink);
const readFile = util.promisify(fs.readFile);

import { AnswerData, schema, parquetInfo, AnswerMetadata, getAnswerMetadata, getSyncDocId } from "./shared/s3-answers"

interface PartialCollaborationData {
  collaborators: {platform_user_id: string}[]
}

/*

HOW THIS WORKS:

1. createSyncDocAfterAnswerWritten runs on every write of an answer.  If the answer changes or is deleted a "sync doc"
   is created or updated whose name is a unique key for the learner-assignment (either a hash of the LTI data or a
   runKey) along with a boolean "updated". For logging purposes, it will also add a last_answer_updated timestamp.
   If a collaborators_data_url is present in the answer (set by the Activity Player) the collaborators_data_url is loaded
   (and cached) and the answer documents are created/updated for each collaborator found in the result.  Each collaborator
   answer has an additional collaboration_owner_id field added that has the value of the platform_user_id of the original
   answer.
2. monitorSyncDocCount runs as a cron job every few minutes to find all the docs with updated = true.  Each document that is
   found has a needs_sync field set to the current server time and has updated set to false.
3. syncToS3AfterSyncDocWritten runs on every write of a sync doc.  If the needs_sync field exists and either the doc has
   never synced before, or needs_sync > did_sync, it will gather up all the answers for that learner-assignment and post
   them to s3 as a parquet file. If there are no answers, it will delete the parquet file. It will then set a did_sync
   timestamp. For logging purposes, it will also set a start_sync timestamp the momement it starts handling the sync_doc,
   and when it finishes it will add some timing info.
*/

const answerDirectory = "partitioned-answers"
const region = "us-east-1"

const monitorSyncDocSchedule = "every 4 minutes"

interface AutoImporterSettings {
  watchAnswers: boolean;
  setNeedSync: boolean;
  sync: boolean;
  portalSecret: string | null;
}

const defaultSettings: AutoImporterSettings = {
  watchAnswers: true,
  setNeedSync: true,
  sync: true,
  portalSecret: null
}

interface S3SyncInfo {
  success: boolean;
  totalTime?: number;
  fileWriterTotalTime?: number;
  s3SendFileTotalTime?: number;
}

interface SyncData {
  updated: boolean;
  answer_metadata: AnswerMetadata;
  last_answer_updated: firestore.Timestamp;
  need_sync?: firestore.Timestamp;
  did_sync?: firestore.Timestamp;
  start_sync?: firestore.Timestamp;
  info?: S3SyncInfo;
}

type PartialSyncData = Partial<SyncData>;

export const getHash = (data: any) => {
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

const escapeKey = (s: string) => s.replace(/[.$[\]#/]/g, "_")

const getSettings = () => {
  return admin.firestore()
    .collection("settings")
    .doc("autoImporter")
    .get()
    .then((doc) => (doc.data() as AutoImporterSettings) || defaultSettings)
    .catch(() => defaultSettings)
}

const getPortalSecret = (platformId: string) => {
  return admin.firestore()
    .collection("settings")
    .doc("portalSecrets")
    .get()
    .then((doc) => {
      const map = doc.data() as Record<string, string>
      return map[escapeKey(platformId)] || null
    })
    .catch(() => null)
}

/**
 * Creates a document in answers_async letting the app know there are answers to be synced
 *
 * @param syncSource The source collection from whence the answer came
 * @param answerMetadata A collection of identifiers that lets us uniquely identify a learner-assignment or anon user
 */
const addSyncDoc = (syncSource: string, answerMetadata: AnswerMetadata) => {
  const syncDocId = getHash(getSyncDocId(answerMetadata));
  if (!syncDocId || !answerMetadata) {
    return Promise.resolve()
  };

  const syncDocRef = getAnswerSyncCollection(syncSource).doc(syncDocId);
  let syncDocData: SyncData = {
    updated: true,
    last_answer_updated: firestore.Timestamp.now(),
    answer_metadata: answerMetadata
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
        // clean up answer objects for parquet
        answer.answer = JSON.stringify(answer.answer)
        delete answer.report_state;
        if (typeof answer.version === "number") {
          answer.version = "" + answer.version;
        }

        await writer.appendRow(answer);
      }
      await writer.close();
      const fileWriterTotalTime = performance.now() - fileWriterStartTime;

      const body = await readFile(tmpFilePath)

      const putObjectCommand = new PutObjectCommand({
        Bucket: functions.config().aws.s3_bucket,
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
    } catch (err: any) {
      reject(err.toString());
    } finally {
      await deleteFile();
      resolve(resultsInfo);
    }
  });
}

const deleteFromS3 = (answerMetadata: AnswerMetadata) => {
  const {key} = parquetInfo(answerDirectory, answerMetadata);
  const deleteObjectCommand = new DeleteObjectCommand({
    Bucket: functions.config().aws.s3_bucket,
    Key: key
  })
  return s3Client().send(deleteObjectCommand)
}

export const isValidCollaboratorsDataUrl = (url: string) => {
  return /^https?:\/\/[^/]*\.concord\.org\//.test(url) || /^https?:\/\/[^/]*\.rigse\.docker\//.test(url)
}

export const getPlatformIdFromUrl = (url: string) => {
  const m = url.match(/https?:\/\/[^/]+/)
  return m ? m[0] : null
}

const verifyCollaborationDataOwner = (collaboratorsDataUrl: string, data: PartialCollaborationData, platformUserId: string) => {
  // for now there is no "owner" specified in the data so we just look to see if they are one of the collaborators
  const collaborator = data.collaborators.find(c => c.platform_user_id === platformUserId)
  if (!collaborator) {
    functions.logger.error(`verifyCollaborationDataOwner: ${platformUserId} was not found in ${collaboratorsDataUrl}`);
  }
  return !!collaborator
}

const fetchCollaborationData = async (collaboratorsDataUrl: string, portalSecret: string): Promise<PartialCollaborationData | null> => {
  try {
    // for local development ignore self-signed certificates
    const agent = new https.Agent({rejectUnauthorized: false});
    const resp = await axios.get(collaboratorsDataUrl, {
      headers: {"Authorization": `Bearer ${portalSecret}`},
      httpsAgent: agent
    })
    return {collaborators: (resp.data as any)}
  } catch (err) {
    functions.logger.error("fetchCollaborationData", err);
    return null;
  }
}

const getCollaborationData = async (collaboratorsDataUrl: string, platformUserId: string): Promise<PartialCollaborationData | null> => {
  // let collaborationData: PartialCollaborationData | undefined

  // check cache first
  const ref = admin.firestore().collection("collaborationDataCache").doc(escapeKey(collaboratorsDataUrl))
  const snapshot = await ref.get()

  let collaborationData = snapshot.data() as PartialCollaborationData | undefined | null
  if (collaborationData && collaborationData.collaborators) {
    // make sure the caller is the owner of the collaboration data
    if (verifyCollaborationDataOwner(collaboratorsDataUrl, collaborationData, platformUserId)) {
      return collaborationData
    } else {
      return null
    }
  } else {
    const platformId = getPlatformIdFromUrl(collaboratorsDataUrl)
    if (!platformId) {
      functions.logger.error(`getCollaborationData: unable to extract plaform id from ${collaboratorsDataUrl}`);
      return null;
    }

    // get the collaboration data from the portal
    const portalSecret = await getPortalSecret(platformId);
    if (!portalSecret) {
      functions.logger.error(`getCollaborationData: no portalSecret found for ${platformId}`);
      return null;
    }

    // fetch and verify the owner of the collaboration data
    collaborationData = await fetchCollaborationData(collaboratorsDataUrl, portalSecret);
    if (!collaborationData || !verifyCollaborationDataOwner(collaboratorsDataUrl, collaborationData, platformUserId)) {
      return null;
    }

    // cache the data if not found
    await ref.set(collaborationData);

    return collaborationData;
  }
}

const handleCollaborativeUrl = (syncSource: string, answerId: string, answerMetadata: AnswerData) => {
  const {collaborators_data_url, platform_id, platform_user_id, collaboration_owner_id, resource_link_id, question_id} = answerMetadata

  // skip if this is an overwrite of collaboration owner answer (to prevent infinite loops) or the required data isn't in the answer
  if (collaboration_owner_id || !collaborators_data_url || !platform_id || !platform_user_id || !resource_link_id || !question_id) {
    return Promise.resolve()
  }

  // filter out invalid urls
  if (!isValidCollaboratorsDataUrl(collaborators_data_url)) {
    functions.logger.error(`handleCollaborativeUrl: invalid collaborators_data_url: ${collaborators_data_url}`);
    return Promise.resolve()
  }

  // get (and cache collaborators data)
  return getCollaborationData(collaborators_data_url, platform_user_id)
    .then(collaborationData => {
      const promises: Promise<any>[] = [];
      if (collaborationData) {
        // update the collaboration owner answer with collaboration_owner_id: true
        promises.push(getAnswersCollection(syncSource).doc(answerId).set({collaboration_owner_id: platform_user_id}, {merge: true}))

        // write the answer to all the other collaborators without the url and rewriting the platform_user_id
        collaborationData.collaborators.forEach(collaborator => {
          if (collaborator.platform_user_id !== platform_user_id) {
            const existingAnswerQuery = getAnswersCollection(syncSource)
              .where("platform_id", "==", platform_id)
              .where("platform_user_id", "==", collaborator.platform_user_id)
              .where("resource_link_id", "==", resource_link_id)
              .where("question_id", "==", question_id);

            const queryPromise = existingAnswerQuery
              .get()
              .then((querySnapshot): Promise<any> => {
                const othersAnswerMetadata = Object.assign({}, answerMetadata, {platform_user_id: collaborator.platform_user_id, collaboration_owner_id: platform_user_id})

                if (querySnapshot.size === 0) {
                  functions.logger.info("handleCollaborativeUrl: adding other user document", {othersAnswerMetadata});
                  return getAnswersCollection(syncSource).add(othersAnswerMetadata)
                } else if (querySnapshot.size === 1) {
                  functions.logger.info("handleCollaborativeUrl: setting other user document", {othersAnswerMetadata});
                  return querySnapshot.docs[0].ref.set(othersAnswerMetadata)
                } else {
                  functions.logger.error("handleCollaborativeUrl: more than one collaborator answer document found", {syncSource, platform_id, platform_user_id, resource_link_id, question_id});
                  return Promise.resolve();
                }
              });

            promises.push(queryPromise);
            return queryPromise;
          }
          return;
        })
      }
      return Promise.all(promises)
    })
}

export const createSyncDocAfterAnswerWritten = functions.firestore
  .document(`${answersPathAllSources}/{answerId}`) // NOTE: {answerId} is a wildcard passed to Firebase
  .onWrite((change, context) => {
    return getSettings()
      .then(({ watchAnswers }) => {
        if (watchAnswers) {
          const currentAnswer = change.after.data() as AnswerData | undefined;
          const previousAnswer = change.before.data() as AnswerData | undefined;

          // if answer was deleted we use the previousAnswer to get the metadata
          const latestAnswerWithMetadata = currentAnswer && currentAnswer.resource_url ? currentAnswer : previousAnswer;
          if (!latestAnswerWithMetadata) {
            return null;
          }

          const answerMetadata = getAnswerMetadata(latestAnswerWithMetadata);
          if (!answerMetadata) {
            return null;
          }

          const beforeHash = previousAnswer ? getHash(previousAnswer) : "";
          const afterHash = currentAnswer ? getHash(currentAnswer) : "";

          if (afterHash !== beforeHash) {
            const {syncSource, answerId} = context.params
            return addSyncDoc(syncSource, answerMetadata).then(() => {
              // only handle collaborative url if answer changed
              return handleCollaborativeUrl(syncSource, answerId, latestAnswerWithMetadata).then(() => null)
            })
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
  .document(`${answersSyncPathAllSources}/{id}`) // {id} is a wildcard passed to Firebase.
  .onWrite((change, context) => {
    return getSettings()
      .then(({ sync }) => {
        if (sync && change.after.exists) {
          const data = change.after.data() as SyncData;

          const needSyncMoreRecentThanDidSync = data.need_sync && (!data.did_sync || (data.need_sync > data.did_sync));
          const needSyncMoreRecentThanStartSync = data.need_sync && (!data.start_sync || (data.need_sync > data.start_sync));

          if (data.need_sync && needSyncMoreRecentThanDidSync && needSyncMoreRecentThanStartSync) {
            const syncDocRef = change.after.ref;

            syncDocRef.update({
              start_sync: firestore.Timestamp.now()
            } as PartialSyncData).catch(functions.logger.error)

            let getAllAnswersForLearner;
            const { answer_metadata } = data;
            if (answer_metadata.platform_id && answer_metadata.resource_link_id && answer_metadata.platform_user_id) {
              getAllAnswersForLearner = getAnswersCollection(context.params.syncSource)
                .where("platform_id", "==", answer_metadata.platform_id)
                .where("resource_link_id", "==", answer_metadata.resource_link_id)
                .where("platform_user_id", "==", answer_metadata.platform_user_id)
            } else if (answer_metadata.run_key) {
              getAllAnswersForLearner = getAnswersCollection(context.params.syncSource)
                .where("run_key", "==", answer_metadata.run_key)
            }
            if (!getAllAnswersForLearner) return null;

            const syncToS3StartTime = performance.now();
            return getAllAnswersForLearner
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
                  deleteFromS3(data.answer_metadata)
                    .catch(functions.logger.error);
                }
              });
          }
        }
        return null;
      });
});
