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
let userArr = [];

const loggedInUserQuery = answersRef
  .orderBy("platform_id", "asc")
  .orderBy("resource_link_id", "asc")
  .orderBy("platform_user_id", "asc")
  .orderBy("question_id", "asc")
  .orderBy("id", "asc");

const anonymousUserQuery = answersRef
  .orderBy("run_key", "asc")
  .orderBy("question_id", "asc")
  .orderBy("id", "asc");

const getLoggedInUserDataKey = (data) => {
  const questionId = data.question_id;
  const userId = data.platform_user_id;
  const resourceLinkId = data.resource_link_id;
  const platformId = data.platform_id;
  return (userId && questionId && resourceLinkId) && `${platformId}/${resourceLinkId}&${userId}@${questionId}`;
}

const getAnonymousUserDataKey = (data) => {
  const questionId = data.question_id;
  const runKey = data.run_key;
  return (runKey && questionId) && `${runKey}@${questionId}`;
}

const storeInfo = (data, dataKey, prevId, id) => {
  if (!dataKey) return;
  if (questionUserMap.has(dataKey)) {
    // console.log(dataKey, "already exists. This data will be deleted: ", data.id);
    answerArr = questionUserMap.get(dataKey);
    if (!answerArr.includes(id)) {
      answerArr.push(id)
    }
  } else {
    questionUserMap.set(dataKey, [data, prevId, id]);
  }
}

const getDocuments = (query) => {
  return query.get()
    .then(answerSnapshot => {
      let prevData = {};
      let prevDataKey = "";
      let count = 0;

      answerSnapshot.forEach(document => {
        if (document.exists) {
          let data = document.data();
          let runKey = data.run_key;
          let questionType = data.questionType;
          // if ((typeof answer == "string") && !(answer.includes("percentageViewed"))) {
            let dataKey = runKey === "" ? getLoggedInUserDataKey(data) : getAnonymousUserDataKey(data);
            (dataKey === prevDataKey) && storeInfo(data, dataKey, prevData.id, data.id)
            prevData = data;
            prevDataKey = dataKey || "";
            count++;

            //count users
            if (!userArr.includes(data.platform_user_id)) {
              userArr.push(data.platform_user_id)
            }
          // }
        } else {
          console.error("No answer found with that id!")
        }
      })
    })
}

getDocuments(loggedInUserQuery).then(() => {
  getDocuments(anonymousUserQuery).then(() => {
    console.log("num users: ", userArr.length);
    console.log(questionUserMap);
    console.log("num duplicates: ", questionUserMap.size);
  })
});