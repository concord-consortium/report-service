
import { Request, Response } from "express"
import { getResourcePath, getDoc } from "./helpers/paths"
import { IPartialLaraAuthoredResource } from "./helpers/lara-types";

export default (req: Request, res: Response) => {
  const resource = req.body as IPartialLaraAuthoredResource;

  getResourcePath(resource)
    .then((path) => {
      return getDoc(path)
        .set(resource)
        .then(() => res.success({"documentPath": path }))
    })
    .catch((e) => {
      console.error(e);
      res.error(500, {error: e})
    })
}
