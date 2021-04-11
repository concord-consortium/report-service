
import { ParseRun }from "../api/import-run"

const runExport = {
  url: "http://google.com/",
  id: "z",
  source_key: "app.lara.docker",
  answers: [
    {question_key: 'a', id: 'a', source_key: "app.lara.docker"},
    {question_key: 'b', id: 'b', source_key: "app.lara.docker"},
    {question_key: 'c', id: 'c', source_key: "app.lara.docker"},
    {question_key: 'd', id: 'd', source_key: "app.lara.docker"}
  ]
}

test('Run Parser', () => {
  const {run, answers = []} = ParseRun(runExport);
  expect(answers.length).toBe(4)
  expect(run.answers).toBeUndefined()
})