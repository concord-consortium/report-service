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

  describe("with a logged in teacher", () => {
    let testApp = null;

    beforeAll(() => {
      testApp = firebase.initializeTestApp({
        projectId: "report-service-dev",
        auth: {
          user_id: "not_sure_what_this_is",
          user_type: "teacher",
          platform_id: "https://portal.concord.org",
          platform_user_id: 12345,
          class_hash: "qwerty"
        }
      });
    })

    afterAll(async () => {
      await testApp.delete();
    });

    it("creates user settings in collections that match the auth", async () => {
      await firebase.assertSucceeds(testApp.firestore()
        .collection(path + "/12345/resource_link")
        .add({setting: "any value"}));
    });

    it("fails to create user settings in other collections", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path + "/23456/resource_link")
        .add({setting: "any value"}));
    });

    it("can read user settings in collections that match the auth", async () => {
      // query document
      const query = await testApp.firestore()
        .collection(path + "/12345/resource_link");

      await firebase.assertSucceeds(query.get());
    });

    it("cannot read user settings in other collections", async () => {
      const query = await testApp.firestore()
        .collection(path + "/23456/resource_link");

      await firebase.assertFails(query.get());
    });

    describe("with an existing user settings doc", () => {
      let settingsDoc = null;

      beforeAll(async () => {
        settingsDoc = await testApp.firestore()
          .collection(path + "/12345/resource_link")
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
          platform_id: "https://portal.concord.org",
          platform_user_id: 123456,
          class_hash: "qwerty"
        }
      });
    })

    afterAll(async () => {
      await testApp.delete();
    });

    it("cannot create user settings", async () => {
      await firebase.assertFails(testApp.firestore()
        .collection(path + "/123456/resource_link")
        .add({some: "value"}));
    });

    it("cannot read user settings", async () => {
      const query = await testApp.firestore()
        .collection(path + "/123456/resource_link");
      await firebase.assertFails(query.get());
    });
  });
});
