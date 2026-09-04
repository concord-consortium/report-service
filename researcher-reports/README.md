# Researcher Reports

## Development

### Initial steps

1. Clone this repo and `cd` into it
2. Run `npm install` to pull dependencies
3. Run `npm start` to run `webpack-dev-server` in development mode with hot module replacement

### Building

If you want to build a local version run `npm build`, it will create the files in the `dist` folder.
You *do not* need to build to deploy the code, that is automatic.  See more info in the Deployment section below.

### Notes

1. Make sure if you are using Visual Studio Code that you use the workspace version of TypeScript.
   To ensure that you are open a TypeScript file in VSC and then click on the version number next to
   `TypeScript React` in the status bar and select 'Use Workspace Version' in the popup menu.

## Deployment

**This app is retired.** It was replaced by the Elixir/Phoenix report server in `server/`, and its
last source change was in October 2023. Nothing reads what its deploy publishes. The release
procedure that used to live here has been removed: it referred to workflows in a
`concord-consortium/researcher-reports` repository that no longer exists, and to two release
workflows in this repository that were deleted because they had never been run.

The deploy still works if the app is ever revived. The `s3-deploy` job in
[`researcher-reports.yml`](../.github/workflows/researcher-reports.yml) publishes to
`models-resources/researcher-reports/`, and runs only when started by hand via
`workflow_dispatch`. See [doc/deploy.md](../doc/deploy.md) for the full story.

The site currently served at http://researcher-reports.concord.org is a frozen October 2023 build.
Its `index.html` points at `version/v1.4.2/` and no workflow updates it.

### Testing

Run `npm test` to run jest tests. Run `npm run test:full` to run jest and Cypress tests.

##### Cypress Run Options

Inside of your `package.json` file:
1. `--browser browser-name`: define browser for running tests
2. `--group group-name`: assign a group name for tests running
3. `--spec`: define the spec files to run
4. `--headed`: show cypress test runner GUI while running test (will exit by default when done)
5. `--no-exit`: keep cypress test runner GUI open when done running
6. `--record`: decide whether or not tests will have video recordings
7. `--key`: specify your secret record key
8. `--reporter`: specify a mocha reporter

##### Cypress Run Examples

1. `cypress run --browser chrome` will run cypress in a chrome browser
2. `cypress run --headed --no-exit` will open cypress test runner when tests begin to run, and it will remain open when tests are finished running.
3. `cypress run --spec 'cypress/integration/examples/smoke-test.js'` will point to a smoke-test file rather than running all of the test files for a project.


## License

Researcher Reports are Copyright 2021 (c) by the Concord Consortium and is distributed under the [MIT license](http://www.opensource.org/licenses/MIT).

See license.md for the complete license text.
