#!/usr/bin/env node
const fs = require("fs");
const { Firestore } = require('@google-cloud/firestore');

process.env.GOOGLE_APPLICATION_CREDENTIALS = "./credentials.json"
if (!fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
  console.error("Missing credentials.json - please create and download a credentials json file here: https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743");
  process.exit(1);
}

const firestore = new Firestore();
const sourceCollection = "activity-player.concord.org"
const answersRef = firestore.collection(`sources/${sourceCollection}/answers`)
let answerArr = [];
let questionUserMap = new Map;

//finds logged in users
const getLoggedInUsers = () => {
  answersRef
  .orderBy("platform_id", "asc")
  .orderBy("resource_link_id", "asc")
  .orderBy("platform_user_id", "asc")
  .orderBy("question_id", "asc")
  .orderBy("id", "asc")
  .get()
  .then(answerSnapshot => {
    let prevData = {};
    let prevDataKey = "";
    let count = 0;
    answerSnapshot.forEach(document => {
      if (document.exists) {
        let data = document.data();
        let questionId = data.question_id;
        let userId = data.platform_user_id;
        let resourceLinkId = data.resource_link_id;
        let platformId = data.platform_id;
        let dataKey = (userId && questionId && resourceLinkId) ? `${platformId}/${resourceLinkId}&${userId}@${questionId}` : undefined;

        if (dataKey === prevDataKey) {
          if (dataKey && questionUserMap.has(dataKey)) {
            console.log(dataKey, "already exists. This data will be deleted: ", data.id);
            // answerArr = questionUserMap.get(dataKey)
            // if (!answerArr.includes(data.id)) {
            //   answerArr.push(data.id)
            // }
          } else {
            questionUserMap.set(prevDataKey, [prevData.id]);
          }
        }
        prevData = data;
        prevDataKey = dataKey;
        count++;
      } else {
        console.error("No answer found with that id!")
      }
    })
    console.log(questionUserMap)
    console.log(questionUserMap.size)
    // var file = fs.createWriteStream("multipleAnswerStudents.txt")
    // questionUserMap.forEach(item => { file.write(item + ", \n") })
    // file.end()
  })
}

const getAnonymousUsers = () => {
  answersRef
  .orderBy("run_key", "asc")
  .orderBy("question_id", "asc")
  .get()
  .then(answerSnapshot => {
    let prevData = {};
    let prevDataKey = "";
    let count = 0;
    answerSnapshot.forEach(document => {
      if (document.exists) {
        let data = document.data();
        let questionId = data.question_id;
        let runKey = data.run_key;
        let dataKey = runKey && questionId ? `${runKey}@${questionId}` : `${data.resource_link_id}&${data.platform_user_id}@${data.question_id}`;

        if ((!runKey=="") && (dataKey === prevDataKey)) {
          if (dataKey && questionUserMap.has(dataKey)) {
          console.log(dataKey, "already exists. This data will be deleted: ", data.id);
            // answerArr = questionUserMap.get(dataKey)
            // if (!answerArr.includes(data.id)) {
            //   answerArr.push(data.id)
            // }
          } else {
            questionUserMap.set(prevDataKey, [prevData.id]);
          }
        }
        prevData = data;
        prevDataKey = dataKey;
        count++;
      } else {
        console.error("No answer found with that id!")
      }
    })
    console.log(questionUserMap)
    console.log(questionUserMap.size)
    // var file = fs.createWriteStream("multipleAnswerStudents.txt")
    // questionUserMap.forEach(item => { file.write(item + ", \n") })
    // file.end()
  })
}

// getLoggedInUsers();
getAnonymousUsers();
