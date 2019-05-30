import admin from "firebase-admin"
import {
  IPartialLaraRun,
  IPartialLaraAnswer,
  IPartialLaraAuthoredResource
} from './lara-types';

const getPath = (source_key:string, type:string, id:string) => {
  return new Promise<string>((resolve, reject) => {
    resolve(`/sources/${source_key}/${type}/${id}`)
  })
}

export const getDoc = (path: string) => {
  return admin.firestore().doc(path)
}

export const getResourcePath = (resource: IPartialLaraAuthoredResource) => {
  const {source_key, id}  = resource
  return getPath(source_key, "resources", id)
}

export const getRunPath = (run: IPartialLaraRun) => {
  const {source_key, id}  = run;
  return getPath(source_key, "runs", id);
}

export const getAnswerPath = (answer: IPartialLaraAnswer) => {
  const {source_key, id}  = answer;
  return getPath(source_key, "answers", id);
}
