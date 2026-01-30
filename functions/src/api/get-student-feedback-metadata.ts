import { Request, Response } from "express"
import { getPath, getCollection } from "./helpers/paths"

interface FeedbackMetadata {
  updatedAt: string;
}
type FeedbackMetadataMap = Record<string, FeedbackMetadata>;

const getFeedbackMetadata = (path: string, platformId: string, platformStudentId: string, map: FeedbackMetadataMap): Promise<FeedbackMetadataMap> => {
  return getCollection(path)
    .where("platformId", "==", platformId)
    .where("platformStudentId", "==", platformStudentId)
    .get()
    .then((snapshot) => {
      snapshot.docs.forEach((doc) => {
        const data = doc.data();
        const {resourceLinkId, updatedAt} = data;
        const seconds = updatedAt?.seconds ?? updatedAt?._seconds;
        if (resourceLinkId && seconds) {
          const existing = map[resourceLinkId];
          if (!existing || seconds > existing.updatedAt) {
            map[resourceLinkId] = {updatedAt: seconds};
          }
        }
      });
      return map;
    });
}

export default (req: Request, res: Response) => {
  const {source, platform_id, platform_student_id} = req.query

  if (!source) {
    return res.error(500, "Missing source in query!")
  }
  if (typeof source !== "string") {
    return res.error(500, "Malformed source")
  }
  if (!platform_id) {
    return res.error(500, "Missing platform_id in query!")
  }
  if (typeof platform_id !== "string") {
    return res.error(500, "Malformed platform_id")
  }
  if (!platform_student_id) {
    return res.error(500, "Missing platform_student_id in query!")
  }
  if (typeof platform_student_id !== "string") {
    return res.error(500, "Malformed platform_student_id")
  }

  return getPath(source, "activity_feedbacks")
    .then((path) => {
      return getFeedbackMetadata(path, platform_id, platform_student_id, {});
    })
    .then((feedbackMetadataMap) => {
      return getPath(source, "question_feedbacks")
        .then((path) => {
          return {path, feedbackMetadataMap};
        });
    })
    .then(({path, feedbackMetadataMap}) => {
      return getFeedbackMetadata(path, platform_id, platform_student_id, feedbackMetadataMap);
    })
    .then((feedbackMetadataMap) => {
      res.success({result: feedbackMetadataMap})
    })
    .catch((e) => {
      console.error(e);
      res.error(404, e.toString())
    })
}
