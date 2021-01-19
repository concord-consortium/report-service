I'm using a locally installed firebase tools. The generally recommended approach is to globally install it.

Install Java

    brew cask install java

That installs open jdk, and doesn't add it to the path so you need to update your shell's config.
The brew command should tell you what is appropriate for your shell.
Without updating the config OS X will continue to tell you that you need to install java.

Start the emulator

    npx firebase -c ../firebase.json emulators:start --only firestore

I got this warning

    Warning: FIRESTORE_EMULATOR_HOST not set, using default value localhost:8080

I suspect that if I use the `-exec` option of the emulator to run the test then it
will set that ENV. So I won't have to worry about it.

You can see the rule coverage after running the tests by looking at this URL:

    http://localhost:8080/emulator/v1/projects/report-service-dev:ruleCoverage.html

To reset the coverage info you have to restart the emulator.

If you change the rules you need to restart the emulator. The emulator seems to
identify the rules have changed, but the tests continue to see the original rules.

For some reason Jest needs to be run with `--env=node`. I got that from here https://stackoverflow.com/a/63465382.
Otherwise, it was failing with an error `INTERNAL ASSERTION FAILED: Unexpected state`.

Some useful example tests: https://github.com/zkohi/firebase-testing-samples/blob/sign_in_provider/__tests__/firestore.rules.test.ts

Useful note about the `auth` object passed to initializeTestApp:
https://github.com/firebase/firebase-tools/issues/2405#issuecomment-651315898

The `auth` object is actually the `token` in the rules.

In order to use the Emulator UI to look at the data in the database from the test runs,
the projectId in the tests, has to match the project id in .firebaserc.
There doesn't seem to be a way to use the Emulator UI to inspect data from other
projectIds. So the projectId of `report-service-dev` is used.

firebase.assertSucceeds is a no-op it just returns the passed in promise
firebase.assertFails chains a promise off of the passed in promise, to check
  that the promise is rejected with a permission denied error. If so, it swallows
  the error. Otherwise it rejects the promise.
Reference: https://github.com/firebase/firebase-js-sdk/blob/master/packages/rules-unit-testing/src/api/index.ts

Because of this it is necessary to `await` for each of these assertions.
