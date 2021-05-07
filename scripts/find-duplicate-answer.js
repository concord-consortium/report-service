#!/usr/bin/env node
const fs = require("fs");
const { Firestore } = require('@google-cloud/firestore');

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const getQuestionKey = (questionUser) => {
  return question = questionUser.split("#")[1].split("@")[0];
}

const firestore = new Firestore();
const answersRef = firestore.collection(`sources/activity-player.concord.org/answers`)
const resourceRef = firestore.collection(`sources/activity-player.concord.org/resources`)
let answerArr = [];
let questionArr = [];
let resourceArr = [];
let questionUserMap = new Map;

answersRef.orderBy("platform_user_id", "asc").orderBy("question_id", "asc").get().then(answerSnapshot => {
  let prevData = {};
  let prevDataKey = "";
  let count = 0;
  answerSnapshot.forEach(document => {
    if (document.exists) {
      let data = document.data();
      let userId = data.platform_user_id;
      let questionId = data.question_id;
      let resourceLinkId = data.resource_link_id ? data.resource_link_id : `anonymous`;
      let dataKey = (userId && questionId && resourceLinkId) ? `${userId}#${questionId}@${resourceLinkId}` : undefined;

      if (dataKey === prevDataKey) {
          if (dataKey && questionUserMap.has(dataKey)) {
            answerArr = questionUserMap.get(dataKey)
            if (!answerArr.includes(prevData.id)) {
              answerArr.push(prevData.id)
            }
          } else {
            questionUserMap.set(prevDataKey, [prevData.id]);
          }
      } else {
        if (prevDataKey && questionUserMap.has(prevDataKey))
          answerArr = questionUserMap.get(prevDataKey)
          if (!answerArr.includes(prevData.id)) {
            answerArr.push(prevData.id)
          }
        }
      }

      prevData = data;
      prevDataKey = dataKey;

    } else {
      console.error("No answer found with that id!")
    }
    count++;
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
  })
  console.log(questionUserMap)
  var file = fs.createWriteStream("multipleAnswerStudents.txt")
  questionUserMap.forEach(item => { file.write(item + ", \n") })
  file.end()

})

