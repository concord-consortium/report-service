const axios = require("axios");
const URL = require('url');

const sequence120 = require("./firebase-data/sequence-120.json");

exports.getResource = async (runnable, reportServiceSource, demo) => {
  if (demo) {
    if (runnable.url === "https://authoring.staging.concord.org/sequences/120") {
      return Promise.resolve(sequence120);
    }
    throw new Error(`Unable to find ${runnable.url}`)
  }

  const reportServiceUrl = `${process.env.REPORT_SERVICE_URL}/resource`

  let runnableUrl = runnable.url;
  const searchParams = new URL(runnableUrl).searchParams;

  if (searchParams) {
    // Activity Player activities that have been imported from LARA have a resource url like
    // https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.staging.concord.org%2Fapi%2Fv1%2Factivities%2F20753.json&firebase-app=report-service-dev
    // This changes the above to https://authoring.staging.concord.org/activities/20753
    const sequenceUrl = searchParams.get("sequence");
    const activityUrl = searchParams.get("activity");
    if (sequenceUrl || activityUrl) {
      runnableUrl = sequenceUrl || activityUrl;
      runnableUrl = runnableUrl.replace("api/v1/", "").replace(".json", "");
    }
  }
  const params = {
    source: reportServiceSource,
    url: runnableUrl
  }

  let response
  try {
    response = await axios.get(reportServiceUrl,
      {
        headers: {
          "Authorization": `Bearer ${process.env.REPORT_SERVICE_TOKEN}`
        },
        params
      }
    )
  } catch (e) {
    throw new Error(`Unable to get resource at ${reportServiceUrl} using ${JSON.stringify(params)}. Error: ${e.toString()}. Response: ${e.response ? JSON.stringify(e.response.data) : "no response"}`)
  }
  const result = response.data
  if (result && result.success && result.resource) {
    return result.resource
  }
  throw new Error(`Unable to find resource at ${reportServiceUrl} using ${JSON.stringify(params)}. Error: ${e.toString()}. Response: ${JSON.stringify(response.data)}`)
}

exports.denormalizeResource = (resource) => {
  const denormalized = {
    questions: {},
    choices: {}
  }

  switch (resource.type) {
    case "activity":
      denormalizeActivity(resource, denormalized);
      break;

    case "sequence":
      resource.children.forEach(activity => denormalizeActivity(activity, denormalized))
      break;

    default:
      throw new Error(`Unknown resource type: ${resource.type}`)
  }

  return denormalized;
}

const denormalizeActivity = (activity, denormalized) => {
  activity.children.forEach(section => {
    section.children.forEach(page => {
      page.children.forEach(question => {
        denormalized.questions[question.id] = {
          prompt: question.prompt
        }
        if (question.type === "multiple_choice") {
          denormalized.choices[question.id] = {}
          question.choices.forEach(choice => {
            denormalized.choices[question.id][choice.id] = {
              content: choice.content,
              correct: choice.correct
            }
          })
        }
      })
    })
  })
}


