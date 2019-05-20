
import { Request, Response } from "express"
import { getDoc, getRunPath } from "./helpers/paths"
import { IPartialLaraRun } from "./helpers/lara-types";

export default (req: Request, res: Response) => {
  const run = req.body as IPartialLaraRun;

  getRunPath(run)
    .then((path) => {
      return getDoc(path)
        .set(run)
        .then(() => res.success({"documentPath": path}))
    })
    .catch((e) => {
      console.error(e);
      res.error(500, {error: e})
    })
}
