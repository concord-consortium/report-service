
import { Request, Response } from "express"
import { getDoc, getAnswerPath } from "./helpers/paths"
import { IPartialLaraAnswer } from "./helpers/lara-types";
import { AnswerData } from "../shared/s3-answers";
import * as functions from "firebase-functions";

export default (req: Request, res: Response) => {
  const extraData: any = {}
  Object.keys(req.query).forEach(key => {
    if (key !== "bearer") {
      extraData[key] = req.query[key]
    }
  })

  const id = `${Date.now()}`
  const answer: AnswerData & IPartialLaraAnswer = {
    id,
    source_key: "fake_answers",
    question_key: `fake_question_${id}`,
    resource_url: "http://example.com/fake",
    platform_id: "http://example.com",
    resource_link_id: "1",
    platform_user_id: "2",
    question_id: `fake_question_${id}`,
    collaborators_data_url: "",
    ...extraData
  }

  functions.logger.info("fakeAnswer", answer);

  return getAnswerPath(answer)
    .then(path => {
      return getDoc(path).set(answer)
        .then(() => res.success({path, answer}))
    })
    .catch((e) => {
      console.error(e);
      res.error(500, {error: e})
    })
}
