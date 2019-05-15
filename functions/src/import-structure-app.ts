import express from "express"
import cors from "cors"

const ImportStructureApp = express()
ImportStructureApp.use(cors({ origin: true }))
ImportStructureApp.get("*", (request, response) => {
  response.send(
    ` <h1>
        Import Activity Structure …
      </h1>
      <h3>
        Path: ${request.path}
      </h3>
    `
  )
})

export default ImportStructureApp