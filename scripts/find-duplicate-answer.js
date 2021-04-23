#!/usr/bin/env node
const fs = require("fs");
const { Firestore } = require('@google-cloud/firestore');

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const firestore = new Firestore();
const answersRef = firestore.collection(`sources/authoring.staging.concord.org/answers`)
let answerArr = [];
let multipleAnswers = [];
let questionUserMap = new Map;

answersRef.get().then(answerSnapshot => {
  answerSnapshot.forEach(document => {
    if (document.exists) {
      let data = document.data();
      let dataKey = (data.platform_user_id && data.question_id)? `${data.platform_user_id}@${data.question_id}`: undefined
      if (dataKey && questionUserMap.has(dataKey)) {
        answerArr = questionUserMap.get(dataKey)

        if (!answerArr.includes(data.id)) {
          answerArr.push(data.id)
        }
      } else {
        questionUserMap.set(dataKey, [data.id]);
      }
    } else {
      console.error("No resource found with that id!")
    }
  })
  for (let [questionUser, answer] of questionUserMap) {
    if (answer.length > 1 ) {
      multipleAnswers.push(questionUser)
    }
  }
  console.log(`length: ${multipleAnswers.length}`)
})

