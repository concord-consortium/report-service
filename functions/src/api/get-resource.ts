
import { Request, Response } from "express"
import { getPath, getDoc } from "./helpers/paths"

export default (req: Request, res: Response) => {
  const id = req.params.id
  const source = req.query.source

  if (!id) {
    return res.error(500, {error: new Error("Missing id in url!")})
  }
  if (!source) {
    return res.error(500, {error: new Error("Missing source in query!")})
  }

  getPath(source, "resources", id)
    .then((path) => {
      return getDoc(path)
        .get()
        .then((snapshot) => res.success({"resource": snapshot.data()}))
    })
    .catch((e) => {
      console.error(e);
      res.error(500, {error: e})
    })
}
