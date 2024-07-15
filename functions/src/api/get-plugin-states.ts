
import { Request, Response } from "express"
import { getPath, getCollection } from "./helpers/paths"

export default (req: Request, res: Response) => {
  const {source, remote_endpoint} = req.query

  if (!source) {
    return res.error(500, "Missing source in query!")
  }
  if (typeof source !== "string") {
    return res.error(500, "Malformed source")
  }
  if (!remote_endpoint) {
    return res.error(500, "Missing remote_endpoint in query!")
  }

  return getPath(source, "plugin_states")
    .then((path) => {
      return getCollection(path)
        .where("remote_endpoint", "==", remote_endpoint)
        .get()
        .then((snapshot) => {
          const pluginStates = snapshot.docs.reduce<Record<string,any>>((acc, doc) => {
            try {
              acc[doc.id] = JSON.parse(doc.data().state)
            } catch (e) {
              // no-op
            }
            return acc
          }, {})
          res.success({"plugin_states": pluginStates})
        })
    })
    .catch((e) => {
      console.error(e);
      res.error(404, e.toString())
    })
}
