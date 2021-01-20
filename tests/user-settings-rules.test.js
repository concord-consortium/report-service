// const firebase = require("firebase/app");
// require("firebase/firestore");
const firebase = require("@firebase/rules-unit-testing");

const path = "sources/example.com/user_settings";

describe("User Settings", () => {
  describe('with an anonymous user', () => {
    let testApp = null;

    beforeAll(() => {
      testApp = firebase.initializeTestApp({
        projectId: "report-service-dev",
        auth: null
      });
    })

    afterAll(async () => {
      await testApp.delete();
    });

    it("fails to create random document at the top level", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path)
        .add({
          randomKey: "hello world"
        }));
    });

    it("fails to create random document in resource_link collection ", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path + "/fake_user/resource_link")
        .add({
          randomKey: "hello world"
        }));
    });

    it("cannot find and read user settings at the top level", async () => {
      const query = testApp.firestore()
        .collection(path);

      await firebase.assertFails(query.get());
    });

    it("cannot find and read user settings in a resource_link collection", async () => {
      const query = testApp.firestore()
        .collection(path + "/fake_user/resource_link");

      await firebase.assertFails(query.get());
    });
  });

  // TODO: These tests would be easier to write and read if we could populate
  // the database with documents regardless of the current rules
  // the docs say we can use initalizeAdminApp for this, but when I tried that
  // there was a complaint about a missing library
  describe("with a logged in teacher", () => {
    let testApp = null;

    beforeAll(() => {
      testApp = firebase.initializeTestApp({
        projectId: "report-service-dev",
        auth: {
          user_id: "not_sure_what_this_is",
          user_type: "teacher",
          // TODO use a typical value here
          platform_id: "https://portal.concord.org",
          // TODO check why we are using string() in the rules
          // perhaps we are sending numbers instead of strings in some cases
          platform_user_id: "abcd",
          class_hash: "qwerty"
        }
      });
    })

    afterAll(async () => {
      await testApp.delete();
    });

    it("creates user settings in collections that match the auth", async () => {
      await firebase.assertSucceeds(testApp.firestore()
        .collection(path + "/abcd/resource_link")
        .add({setting: "any value"}));
    });

    it("fails to create user settings in other collections", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path + "/other-user/resource_link")
        .add({setting: "any value"}));
    });

    it("can read user settings in collections that match the auth", async () => {
      // query document
      const query = await testApp.firestore()
        .collection(path + "/abcd/resource_link");

      await firebase.assertSucceeds(query.get());
    });

    it("cannot read user settings in other collections", async () => {
      const query = await testApp.firestore()
        .collection(path + "/other-user/resource_link");

      await firebase.assertFails(query.get());
    });

    // Security: currently the platform_id of the user id is not checked here
    //   so a different platform could provide a JWT with the same user id
    //   and the teacher could then read and write the other platform's settings
    // TODO: the source part of the path could be used to secure this better.
    //   Currently the settings are only written by portal-report so its method
    //   of computing the source could be used here, or the data could be migrated
    //   to bring this more inline with the rest of the documents

    describe("with an existing user settings doc", () => {
      let settingsDoc = null;

      beforeAll(async () => {
        settingsDoc = await testApp.firestore()
          .collection(path + "/abcd/resource_link")
          .add({setting: "any value"});
      });

      it("can update the user settings doc with new content", async () => {
        await firebase.assertSucceeds(settingsDoc.
          update({
            fakeProperty: "some value"
          }));
      });
    });

  });

  describe("with a logged in student", () => {
    let testApp = null;

    beforeAll(() => {
      testApp = firebase.initializeTestApp({
        projectId: "report-service-dev",
        auth: {
          user_id: "not_sure_what_this_is",
          user_type: "learner",
          // TODO use a typical value here
          platform_id: "https://portal.concord.org",
          // This value isn't strictly necessary for testing answers by teachers
          // but other document types might need it
          platform_user_id: "abcd-student",
          class_hash: "qwerty"
        }
      });
    })

    afterAll(async () => {
      await testApp.delete();
    });

    it("cannot create user settings", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path + "/abcd/resource_link")
        .add({some: "value"}));
    });

    it("cannot read user settings", async () => {
      const query = await testApp.firestore()
        .collection(path + "/abcd/resource_link");
      await firebase.assertFails(query.get());
    });
  });
});
