const axios = require("axios");

const sequence120 = require("./firebase-data/sequence-120.json");

exports.getResource = async (runnable, reportServiceSource, demo) => {
  if (demo) {
    if (runnable.url === "https://authoring.staging.concord.org/sequences/120") {
      return Promise.resolve(sequence120);
    }
    throw new Error(`Unable to find ${runnable.url}`)
  }

  const url = `${process.env.REPORT_SERVICE_URL}/resource`
  const params = {
    source: reportServiceSource,
    url: runnable.url
  }

  let response
  try {
    response = await axios.get(url,
      {
        headers: {
          "Authorization": `Bearer ${process.env.REPORT_SERVICE_TOKEN}`
        },
        params
      }
    )
  } catch (e) {
    throw new Error(`Unable to get resource at ${url} using ${JSON.stringify(params)}. Error: ${e.toString()}. Response: ${error.response ? JSON.stringify(error.response.data) : "no response"}`)
  }
  const result = response.data
  if (result && result.success && result.resource) {
    return result.resource
  }
  throw new Error(`Unable to find resource at ${url} using ${JSON.stringify(params)}. Error: ${e.toString()}. Response: ${JSON.stringify(response.data)}`)
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


