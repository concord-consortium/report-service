import { Request, Response } from "express"
import { getDoc, getRunPath, getAnswerPath } from "./helpers/paths"

export const ParseStudentWork = (body) => {
  const classInfoUrl = body.class_info_url
  const contextId = body.context_id
  const platformId = body.platform_id
  const platformUserId = body.platform_user_id
  const assignments = body.assignments

  return {classInfoUrl: classInfoUrl, contextID: contextId, platformId: platformId, platformUserId: platformUserId, assignments: assignments}
}

export default (req: Request, res: Response) => {

  const {classInfoUrl, contextId, platformId, platformUserId, assignments} = ParseStudentWork(req.body)

  assignments.forEach((assignment, i) => {
    let toolId = assignment.tool_id
    let data = {class_info_url: classInfoUrl, context_id: contextId, platform_id: platformId, resource_link_id: assignment.new_resource_link_id}

    let answersQuery = db.collection(`sources/${toolId}/answers`)
      .where("context_id", "==", contextId)
      .where("platform_id", "==", platformId)
      .where("platform_user_id", "==", platformUserId.toString())
      .where("resource_link_id", "==", assignment.old_resource_link_id.toString())
      .get()
      .then((QuerySnapshot) => {
        QuerySnapshot.forEach((document) => {
          document.ref().set(data, {merge: true})
        })
      })
      .catch((e) => {
        console.error(e);
        res.error(500, {error: e})
      })
  }
}
