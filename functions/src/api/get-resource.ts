
import { Request, Response } from "express"
import { getPath, getCollection } from "./helpers/paths"

export default (req: Request, res: Response) => {
  const {source, url} = req.query

  if (!source) {
    return res.error(500, "Missing source in query!")
  }
  if (!url) {
    return res.error(500, "Missing url in query!")
  }
  if (typeof source !== "string") {
    return res.error(500, "Malformed source")
  }

  return getPath(source, "resources")
    .then((path) => {
      return getCollection(path)
        .where("url", "==", url)
        .get()
        .then((snapshot) => {
          if (snapshot.size === 0) {
            throw new Error("Resource not found!")
          } else if (snapshot.size > 1) {
            throw new Error("Multiple resources with the same url not found!")
          } else {
            res.success({"resource": snapshot.docs[0].data()})
          }
        })
    })
    .catch((e) => {
      console.error(e);
      res.error(500, e.toString())
    })
}
