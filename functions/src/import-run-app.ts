import express from "express"
import cors from "cors"

// A placeholder app for the firebase function that imports learner data
const ImportRunApp = express()
ImportRunApp.use(cors({ origin: true }))
ImportRunApp.get("*", (request, response) => {
  response.send(
    ` <h1>
        Import Student Run …
      </h1>
      <h3>
        Path: ${request.path}
      </h3>
    `
  )
})

export default ImportRunApp