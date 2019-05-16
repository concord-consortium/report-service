
import crypto from 'crypto'
import express from "express"
import admin from "firebase-admin"

type IResourceType = 'Activity' | 'Sequence';

interface IAuthoredResource {
  url: string;
  author_email: string;
  type: IResourceType;
}

const hashKey =  (input:string) => {
  if (input && input.length > 1) {
    const shaSum = crypto.createHash('sha1');
    shaSum.update(input);
    return shaSum.digest('hex');
  } else {
    throw new Error(`Can't create hashKey from string:${input}`)
  }
}

const genHostKey = (url:string) => {
  const re = /https?:\/\/([^/]+)/
  const match = url.match(re) || []
  const hostPart = match[1]
  if (!hostPart) {
    throw new Error("Host Name not found in url, or url missing")
  }
  return hostPart.replace(/\./g, '_')
}

const getPath = (hostKey:string, contentKey:string) => `/sources/${hostKey}/resources/${contentKey}`


export default (req: express.Request, res: express.Response) => {
  const errorCode  = 500;
  const resourceContent = req.body as IAuthoredResource;
  try {
    const {url} = resourceContent;
    const contentKey = hashKey(url)
    const hostKey = genHostKey(url)
    const path = getPath(hostKey, contentKey)
    const db = admin.firestore()
    const doc = db.doc(path)
    doc.set(resourceContent)
      .then( () => res.success( {"documentPath": path} ))
      .catch( (e) => res.error(errorCode, {error: e} ))
  }
  catch(e) {
    console.error(e);
    res.error(errorCode, {error: e})
  }
}
