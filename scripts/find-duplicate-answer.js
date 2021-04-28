#!/usr/bin/env node
const fs = require("fs");
const { Firestore } = require('@google-cloud/firestore');

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const getQuestionKey = (questionUser) => {
  return question = questionUser.split("@")[1]
}

const firestore = new Firestore();
const answersRef = firestore.collection(`sources/authoring.staging.concord.org/answers`)
const resourceRef = firestore.collection(`sources/authoring.staging.concord.org/resources`)
let answerArr = [];
let questionArr = [];
let resourceArr = [];
let questionUserMap = new Map;

answersRef.orderBy("platform_user_id", "asc").orderBy("question_id", "asc").get().then(answerSnapshot => {
  let prevUserId = "";
  let prevQuestionId = "";
  answerSnapshot.forEach(document => {
    if (document.exists) {
      let data = document.data();
      let userId = data.platform_user_id;
      let questionId = data.question_id;
      if ((userId === prevUserId) && (questionId === prevQuestionId)) {
        let dataKey = (userId && questionId) ? `${userId}@${questionId}` : undefined
        if (dataKey && questionUserMap.has(dataKey)) {
          answerArr = questionUserMap.get(dataKey)

          if (!answerArr.includes(data.id)) {
            answerArr.push(data.id)
          }
        } else {
          questionUserMap.set(dataKey, [data.id]);
        }
      }
      prevUserId = userId;
      prevQuestionId = questionId;
    } else {
      console.error("No answer found with that id!")
    }
  })

  for (let [questionUser] of questionUserMap) {
    let questionId = questionUser && getQuestionKey(questionUser)
    if (!questionArr.includes(questionId)) {
      questionArr.push(questionId)
    }
  }

  resourceRef.get().then(resourceSnapshot => {
    resourceSnapshot.forEach(resource => {
      if (resource.exists) {
        let activity = resource.data()
        let pages = activity.children
        pages.forEach(page => {
          let sections = page.children
          sections.forEach(section => {
            let parts = section.children
            parts.forEach(part => {
              if (!part.id.includes("page")) {
                if (questionArr.includes(part.id) && !resourceArr.includes(part.id)) {
                  resourceArr.push(resource)
                }
              }
            })
          })
        })
      }
    })
    console.log(resourceArr.length)
  })

  // var file = fs.createWriteStream("multipleAnswerStudents.txt")
  // multipleAnswers.forEach(item=>{file.write(item + ", \n")})
  // file.end()

})

