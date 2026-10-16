import admin from "firebase-admin"
import * as functions from "firebase-functions"
import { handleAnswerWrite, Skip } from "./activity"

const ANSWERS = "sources/{source}/answers/{answerId}"
const BAD_DATA = new Set<Skip>(["bad_platform_id", "bad_class_hash", "bad_user_id", "bad_resource_link_id"])

// The per-learner activity document the dashboard listens to, updated on every qualifying answer write.
// Retried on failure: a lost delivery of a lesson's last save would leave a result never marked behind.
export const researcherDashboardActivity = functions
  .runWith({ failurePolicy: true })
  .firestore.document(ANSWERS)
  .onWrite(async (change, context) => {
    const skip = await handleAnswerWrite(admin.firestore(), change.before.data(), change.after.data())
    if (skip && BAD_DATA.has(skip)) {
      functions.logger.warn("activity.skipped", { reason: skip, ...context.params })
    }
    return null
  })
