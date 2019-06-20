
import { Request, Response } from "express"
import { getDoc, getRunPath, getAnswerPath } from "./helpers/paths"
import { IPartialLaraRun } from "./helpers/lara-types";


export const ParseRun = (body: IPartialLaraRun) => {
  const run = body
  const answers = run.answers
  delete(run.answers)
  return {run: run, answers: answers}
}

export default (req: Request, res: Response) => {
  const {run, answers} = ParseRun(req.body)

  getRunPath(run)
    .then((path) => {
      return getDoc(path)
        .set(run)
        .then(() => {
          const answerPromises = answers.map( (answer) => {
            return getAnswerPath(answer)
              .then((answerPath) => getDoc(answerPath).set(answer))
          })
          return Promise.all(answerPromises)
        })
        .then(() => res.success({"documentPath": path}))
    })
    .catch((e) => {
      console.error(e);
      res.error(500, {error: e})
    })
}
