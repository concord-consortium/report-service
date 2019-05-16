import express from "express"

export default (req: express.Request, res: express.Response) => {
  res.success(
    ` <h1>
        Import Structure …
      </h1>
      <h3>
        Path: ${req.path}
      </h3>
    `
  )
}
