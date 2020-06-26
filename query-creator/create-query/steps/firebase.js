const axios = require("axios");

const activity100 = require("./firebase-data/activity-100.json");
const sequence100 = require("./firebase-data/sequence-100.json");

exports.getResource = async (runnable, reportServiceSource) => {
  // const url = `${process.env.REPORT_SERVICE_URL}/resource/${runnable.type}-${runnable.type}_${runnable.id}?source=${reportServiceSource}`
  // const response = await axios.get(url, { headers: { "Authorization": `Bearer ${process.env.REPORT_SERVICE_TOKEN}` } })
  // return JSON.parse(response.resource)

  if (runnable.type === "activity") {
    return Promise.resolve(activity100);
  }
  if (runnable.type === "sequence") {
    return Promise.resolve(sequence100);
  }
  throw new Error(`Unable to find ${runnable.type}#${runnable.id}`)
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


