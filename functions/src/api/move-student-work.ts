import admin from "firebase-admin"
import { Request, Response } from "express"

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
const processAssignment = (assignment: any, config: any) => {
  console.log('Iteration through assignments begun.')
  const sourceKey = makeSourceKey(assignment.tool_id)
  console.log('Tool ID set: ' + sourceKey)
  const data = {
    class_info_url: config.classInfoUrl,
    context_id: config.newContextId,
    platform_id: config.platformId,
    resource_link_id: assignment.new_resource_link_id
  }
  console.log('Data set: ' + data)
  return admin.firestore().collection(`sources/${sourceKey}/answers`)
    .where("context_id", "==", config.currentContextId)
    .where("platform_id", "==", config.platformId)
    .where("platform_user_id", "==", config.platformUserId.toString())
    .where("resource_link_id", "==", assignment.current_resource_link_id.toString())
    .get()
    .then((querySnapshot) => {
      console.log('Number of matching docs in querySnapshot: ' + querySnapshot.size)
      if (querySnapshot.size <= 0) {
        console.log('No matching docs for context_id=' + config.currentContextId +
          ' & platform_id=' + config.platformId +
          ' & platform_user_id=' + config.platformUserId +
          ' & resource_link_id=' + assignment.current_resource_link_id.toString())
      }
      const answerProcessingPromises =
        querySnapshot.docs.map(answerDoc => processAnswer(answerDoc, data))
      return Promise.all(answerProcessingPromises)
    })
}

export default (req: Request, res: Response) => {
  console.log('Move started.')
  const body = req.body
  const config = {
    classInfoUrl: body.class_info_url,
    currentContextId: body.current_context_id,
    newContextId: body.context_id,
    platformId: body.platform_id,
    platformUserId: body.platform_user_id
  }
  console.log('Variables set from submitted JSON.')
  Promise.all(body.assignments.map((assignment: any) => processAssignment(assignment, config)))
    .then( (success) => {
      res.status(200).send("Success")
      console.log('Work updated.')
    })
    .catch( (e) => {
      console.error(e)
      res.status(500).send("Error")
    })
}
