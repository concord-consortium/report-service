import crypto from 'crypto'
import admin from "firebase-admin"
import { IPartialLaraRun, IPartialLaraAuthoredResource } from './lara-types';

const hashKey = (input:string) => {
  return new Promise<string>((resolve, reject) => {
    if (input && input.length > 1) {
      const shaSum = crypto.createHash('sha1');
      shaSum.update(input);
      resolve(shaSum.digest('hex'))
    } else {
      reject(`Can't create hashKey from string:${input}`)
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
      reject("Host Name not found in url, or url missing")
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
    return hashKey(resource.url).then((resourceKey) => `${sourcePath}/resources/${resourceKey}`)
  })
}

export const getRunPath = (run: IPartialLaraRun) => {
  return getSourcePath(run.url).then((sourcePath) => `${sourcePath}/runs/${run.key}`)
}

