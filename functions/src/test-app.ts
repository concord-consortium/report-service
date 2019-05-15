import express from "express"
import cors from "cors"

// A simple example app to mount and experiment with
const TestApp = express()
TestApp.use(cors({ origin: true }))
TestApp.get("*", (request, response) => {
  response.send(
    ` <h1>
        Hello from Express test.
      </h1>
      <h3>
        Path: ${request.path}
      </h3>
    `
  )
})

export default TestApp