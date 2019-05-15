import WrapExpressApp from "./express-wrapper";
import TestApp from "./test-app";
import ImportStructureApp from "./import-structure-app"
import ImportRunApp from "./import-run-app"

// Without these next two lines we see this error:
// The Firebase Admin module has not been initialized early enough.
// Make sure you run "admin.initializeApp()" outside of any function …
const admin = require('firebase-admin');
admin.initializeApp();

// not as clean, but a better endpoint to consume
const test = WrapExpressApp(TestApp)
const importStructure = WrapExpressApp(ImportStructureApp)
const importRun = WrapExpressApp(ImportRunApp)

module.exports = {
  test,
  importStructure,
  importRun
}

