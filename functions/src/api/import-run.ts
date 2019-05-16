import express from "express"

export default (req: express.Request, res: express.Response) => {
  res.success(
    ` <h1>
        Import Student Run …
      </h1>
      <h3>
        Path: ${req.path}
      </h3>
    `
  )
}
