
import { Request, Response } from "express"
import { getPath, getCollection } from "./helpers/paths"

export default (req: Request, res: Response) => {
  const {source, remote_endpoint, question_id} = req.query

  if (!source) {
    return res.error(500, "Missing source in query!")
  }
  if (typeof source !== "string") {
    return res.error(500, "Malformed source")
  }
  if (!remote_endpoint) {
    return res.error(500, "Missing remote_endpoint in query!")
  }
  if (!question_id) {
    return res.error(500, "Missing question_id in query!")
  }

  return getPath(source, "answers")
    .then((path) => {
      return getCollection(path)
        .where("remote_endpoint", "==", remote_endpoint)
        .where("question_id", "==", question_id)
        .get()
        .then((snapshot) => {
          if (snapshot.size === 0) {
            throw new Error("Answer not found!")
          } else if (snapshot.size > 1) {
            throw new Error("Multiple answers with the same remote_endpoint and question_id found!")
          } else {
            res.success({"answer": snapshot.docs[0].data()})
          }
        })
    })
    .catch((e) => {
      console.error(e);
      res.error(500, e.toString())
    })
}
