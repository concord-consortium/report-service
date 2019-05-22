import admin from "firebase-admin"
import {
  IPartialLaraRun,
  IPartialLaraAnswer,
  IPartialLaraAuthoredResource
} from './lara-types';

const resourceKey = (url:string) => {
  return new Promise<string>((resolve, reject) => {
    const re = /(https?:\/\/)(.*)/
    const match = url.match(re) || []
    const hostPath = match[2]
    if (hostPath) {
      resolve(hostPath.replace(/\.|\//g, '_'))
    } else {
      reject(`hostPath not found in url, or url missing ${url}`)
    }
  })
}

const genSourceKey = (url:string) => {
  return new Promise<string>((resolve, reject) => {
    const re = /https?:\/\/([^/]+)/
    const match = url.match(re) || []
    const hostPart = match[1]
    if (hostPart) {
      resolve(hostPart.replace(/\./g, '_'))
    } else {
      reject(`Host Name not found in url, or url missing ${url}`)
    }
  })
}

export const getDoc = (path: string) => {
  return admin.firestore().doc(path)
}

export const getSourcePath = (url: string) => {
  return genSourceKey(url).then((sourceKey) => `/sources/${sourceKey}`)
}

export const getResourcePath = (resource: IPartialLaraAuthoredResource) => {
  return getSourcePath(resource.url).then((sourcePath) => {
    return resourceKey(resource.url).then((key) => `${sourcePath}/resources/${key}`)
  })
}

export const getRunPath = (run: IPartialLaraRun) => {
  return getSourcePath(run.url).then((sourcePath) => `${sourcePath}/runs/${run.key}`)
}

export const getAnswerPath = (answer: IPartialLaraAnswer) => {
  return getSourcePath(answer.url)
    .then((sourcePath) => `${sourcePath}/answers/${answer.key}`)
}
