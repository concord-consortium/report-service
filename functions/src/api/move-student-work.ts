import admin from "firebase-admin"
import { Request, Response } from "express"
import { IPortalMoveStudentsConfig, IPortalMoveStudentsAssignment } from "./helpers/portal-types";

// This matches the make_source_key method in LARA's report_service.rb
const makeSourceKey = (toolId: string) => {

  return toolId.replace(/http[|s]?:\/\/([^\/]+)/, "$1")
}

const processAnswer = (answerDoc: any, data: any) => {
  const ref = answerDoc.ref
  return ref.set(data, {merge: true})
}

// this returns a promise that resolves
// once all of the answer documents of the user have been updated
const processAssignment = (assignment: IPortalMoveStudentsAssignment, config: IPortalMoveStudentsConfig) => {
  if (!assignment.tool_id) {
    return Promise.resolve(null)
  }
  const sourceKey = makeSourceKey(assignment.tool_id)
  const data = {
    class_info_url: config.new_class_info_url,
    context_id: config.new_context_id,
    platform_id: config.platform_id,
    resource_link_id: assignment.new_resource_link_id
  }
  console.log('Process Assignment -- Source Key: ' + sourceKey + ', Data: ' + JSON.stringify(data))
  return admin.firestore().collection(`sources/${sourceKey}/answers`)
    .where("context_id", "==", config.old_context_id)
    .where("platform_id", "==", config.platform_id)
    .where("platform_user_id", "==", config.platform_user_id)
    .where("resource_link_id", "==", assignment.old_resource_link_id)
    .get()
    .then((querySnapshot) => {
      console.log('Number of matching answers: ' + querySnapshot.size)
      if (querySnapshot.size <= 0) {
        console.log('No matching docs for context_id=' + config.old_context_id +
          ' & platform_id=' + config.platform_id +
          ' & platform_user_id=' + config.platform_user_id +
          ' & resource_link_id=' + assignment.old_resource_link_id)
      }
      const answerProcessingPromises =
        querySnapshot.docs.map(answerDoc => processAnswer(answerDoc, data))
      return Promise.all(answerProcessingPromises)
    })
}

export default (req: Request, res: Response) => {
  const config = req.body as IPortalMoveStudentsConfig
  Promise.all(config.assignments.map((assignment) => processAssignment(assignment, config)))
    .then( (success) => {
      res.status(200).send("Success")
    })
    .catch( (e) => {
      console.error(e)
      res.status(500).send("Error")
    })
}
