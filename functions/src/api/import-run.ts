import express from "express"

export default (req: express.Request, res: express.Response) => {
  res.success(
   {
     "payload": req.body,
     "path": req.path
   }
  )
}
