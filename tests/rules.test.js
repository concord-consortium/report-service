// const firebase = require("firebase/app");
// require("firebase/firestore");
const firebase = require("@firebase/rules-unit-testing");


describe('with an anonymous user', () => {
  let testApp = null;

  beforeAll(() => {
    testApp = firebase.initializeTestApp({
      projectId: "report-service-dev",
      // projectId: "my-test-project",
      auth: null
    });
  })

  afterAll(async () => {
    await testApp.delete();
  });

  it('creates run_key answers regardless of auth', async () => {
    await firebase.assertSucceeds(testApp.firestore()
      .collection("sources/example.com/answers")
      .add({
        run_key: "0123456789A"
      }));
  });

  it('fails to create run_key answers with platform_id', async () => {
    await firebase.assertFails(testApp.firestore()
      .collection("sources/example.com/answers")
      .add({
        run_key: "0123456789A",
        platform_id: "fake_platform_id"
      }));
  });

  describe('with an existing run_key document', () => {
    let runKeyDoc = null;

    beforeAll(async () => {
      runKeyDoc = await testApp.firestore()
        .collection("sources/example.com/answers")
        .add({
          run_key: "0123456789A"
        });
    })

    it('can update a document with new content', async () => {
      await firebase.assertSucceeds(runKeyDoc.
        update({
          fakeProperty: "some value"
        }));
    });

    it('cannot change the run_key of a document', async () => {
      await firebase.assertFails(runKeyDoc.
        update({
          run_key: "some value longer than 10"
        }));
    });

    it('cannot set the platform id of a run_key document', async () => {
      await firebase.assertFails(runKeyDoc.
        update({
          platform_id: "example.com"
        }));
    });

    it('can find and read the run_key document', async () => {
      expect.assertions(1);
      const query = testApp.firestore()
        .collection("sources/example.com/answers")
        .where("run_key", "==", "0123456789A");

      const querySnapshot = await query.get();
      expect(querySnapshot.empty).toBe(false);
    });

  });
});

// TODO: These tests would be easier to write and read if we could populate
// the database with documents regardless of the current rules
// the docs say we can use initalizeAdminApp for this, but when I tried that
// there was a complaint about a missing library
describe("with a logged in learner", () => {
  let testApp = null;
  let testAppOtherClass = null;
  let testAppOtherStudent = null;

  beforeAll(() => {
    testApp = firebase.initializeTestApp({
      projectId: "report-service-dev",
      // projectId: "my-test-project",
      auth: {
        user_id: "not_sure_what_this_is",
        user_type: "learner",
        // TODO use a typical value here
        platform_id: "https://portal.concord.org",
        // TODO check why we are using string() in the rules
        // perhaps we are sending numbers instead of strings in some cases
        platform_user_id: "abcd",
        class_hash: "qwerty"
      }
    });

    testAppOtherClass = firebase.initializeTestApp({
      projectId: "report-service-dev",
      // projectId: "my-test-project",
      auth: {
        user_id: "not_sure_what_this_is",
        user_type: "learner",
        // TODO use a typical value here
        platform_id: "https://portal.concord.org",
        platform_user_id: "abcd",
        class_hash: "different-qwerty"
      }
    });

    testAppOtherStudent = firebase.initializeTestApp({
      projectId: "report-service-dev",
      // projectId: "my-test-project",
      auth: {
        user_id: "not_sure_what_this_is",
        user_type: "learner",
        // TODO use a typical value here
        platform_id: "https://portal.concord.org",
        platform_user_id: "abcd-other-student",
        class_hash: "qwerty"
      }
    });
  })

  afterAll(async () => {
    await testApp.delete();
    await testAppOtherClass.delete();
    await testAppOtherStudent.delete();
  });

  const validAnswer = {
    platform_id: "https://portal.concord.org",
    context_id: "qwerty",
    platform_user_id: "abcd"
  };

  it('creates answers that match the auth', async () => {
    await firebase.assertSucceeds(testApp.firestore()
      .collection("sources/example.com/answers")
      .add(validAnswer));
  });

  it('fails to create answers that with incorrect platform_id', async () => {
    await firebase.assertFails(testApp.firestore()
      .collection("sources/example.com/answers")
      .add({
          ...validAnswer,
          platform_id: "incorrect platform id"
      }));
  });

  it('fails to create answers that with incorrect context_id', async () => {
    await firebase.assertFails(testApp.firestore()
      .collection("sources/example.com/answers")
      .add({
          ...validAnswer,
          context_id: "incorrect context id"
      }));
  });

  it('fails to create answers that with incorrect platform_user_id', async () => {
    await firebase.assertFails(testApp.firestore()
      .collection("sources/example.com/answers")
      .add({
          ...validAnswer,
          platform_user_id: "incorrect platform user id"
      }));
  });

  describe('with an existing learner answer', () => {
    let runKeyDoc = null;

    beforeAll(async () => {
      learnerDoc = await testApp.firestore()
        .collection("sources/example.com/answers")
        .add(validAnswer);
    })

    it('can update a document with new content', async () => {
      await firebase.assertSucceeds(learnerDoc.
        update({
          fakeProperty: "some value"
        }));
    });

    // Note: There doesn't seem to be a way to test that learnerOwner() returns
    // false during an answer update by a learner.
    // I don't see a way for a learner to access a documentRef from a
    // document they don't own

    it('cannot change the platform_id of a document', async () => {
      await firebase.assertFails(learnerDoc.
        update({
          platform_id: "invalid platform_id"
        }));
    });

    it('cannot change the platform_user_id of a document', async () => {
      await firebase.assertFails(learnerDoc.
        update({
          platform_user_id: "invalid platform_user_id"
        }));
    });

    it('cannot change the context_id of a document', async () => {
      await firebase.assertFails(learnerDoc.
        update({
          context_id: "invalid context_id"
        }));
    });

    it('can read the existing answer', async () => {
      // query document
      const query = await testApp.firestore()
        .collection("sources/example.com/answers")
        .where("platform_id", "==", "https://portal.concord.org")
        .where("platform_user_id", "==", "abcd")
        .where("context_id", "==", "qwerty");

      await firebase.assertSucceeds(query.get());
    });

    it('cannot read an existing answer from a different student', async () => {
      // Create the answer from a different student
      await testAppOtherStudent.firestore()
        .collection("sources/example.com/answers")
        .add({
            ...validAnswer,
            platform_user_id: "abcd-other-student"
        });

      // query document
      const query = await testApp.firestore()
        .collection("sources/example.com/answers")
        .where("platform_id", "==", "https://portal.concord.org")
        .where("platform_user_id", "==", "abcd-other-student")
        .where("context_id", "==", "qwerty");

      await firebase.assertFails(query.get());
    });


    // check changing context id see checkme in rules
    it('cannot change the context_id of a document from a different class', async () => {
      expect.assertions(1);

      // Create the document in a different class
      await testAppOtherClass.firestore()
        .collection("sources/example.com/answers")
        .add({
            ...validAnswer,
            context_id: "different-qwerty"
        });

      // read document using the main classes app
      // This is not a query that the portal report would do, but a user that is hacking
      // our apps could do a query like this
      const query = await testApp.firestore()
        .collection("sources/example.com/answers")
        .where("platform_id", "==", "https://portal.concord.org")
        .where("platform_user_id", "==", "abcd")
        .where("context_id", "==", "different-qwerty");

      const querySnapshot = await query.get();

      expect(querySnapshot.empty).toBe(false);

      // FIXME: when run multiple times this might not return the most recent document
      // we should probably clear the database before running the tests
      const otherClassDoc = querySnapshot.docs[0].ref;

      // Try to change this documents context_id to something the student currently
      // has access to.  They shouldn't be changing this, so this should fail.
      await firebase.assertFails(otherClassDoc.
        update({
          context_id: "qwerty"
        }));

    });

  });

});

describe("with a logged in teacher", () => {
  let testApp = null;

  beforeAll(() => {
    testApp = firebase.initializeTestApp({
      projectId: "report-service-dev",
      // projectId: "my-test-project",
      auth: {
        user_id: "not_sure_what_this_is",
        user_type: "teacher",
        // TODO use a typical value here
        platform_id: "https://portal.concord.org",
        // This value isn't strictly necessary for testing answers by teachers
        // but other document types might need it
        platform_user_id: "abcd-teacher",
        class_hash: "qwerty"
      }
    });
  })

  afterAll(async () => {
    await testApp.delete();
  });

  const invalidTeacherAnswer = {
    platform_id: "https://portal.concord.org",
    context_id: "qwerty",
    platform_user_id: "abcd-teacher"
  };

  it("cannot create answers", async () => {
    await firebase.assertFails(testApp.firestore()
      .collection("sources/example.com/answers")
      .add(invalidTeacherAnswer));
  });

  it("can read a student answer in same context", async () => {
    const query = testApp.firestore()
      .collection("sources/example.com/answers")
      .where("platform_id", "==", "https://portal.concord.org")
      .where("context_id", "==", "qwerty");
    await firebase.assertSucceeds(query.get());
  })

  it("cannot read a student answer in different context", async () => {
    const query = testApp.firestore()
      .collection("sources/example.com/answers")
      .where("platform_id", "==", "https://portal.concord.org")
      .where("context_id", "==", "qwerty-other");
    await firebase.assertFails(query.get());
  })

  describe("with an existing student answer", () => {

    beforeAll(async () => {
      const testAppStudent = firebase.initializeTestApp({
        projectId: "report-service-dev",
        // projectId: "my-test-project",
        auth: {
          user_id: "not_sure_what_this_is",
          user_type: "learner",
          // TODO use a typical value here
          platform_id: "https://portal.concord.org",
          platform_user_id: "abcd",
          class_hash: "qwerty"
        }
      });

      await testAppStudent.firestore()
        .collection("sources/example.com/answers")
        .add({
          platform_id: "https://portal.concord.org",
          context_id: "qwerty",
          platform_user_id: "abcd"
        });

      await testAppStudent.delete();
    });

    it("cannot update student answer", async () => {
      expect.assertions(1);
      const query = await testApp.firestore()
        .collection("sources/example.com/answers")
        .where("platform_id", "==", "https://portal.concord.org")
        .where("context_id", "==", "qwerty");
      const querySnapshot = await query.get();
      expect(querySnapshot.empty).toBe(false);
      const studentAnswerRef = querySnapshot.docs[0].ref;

      await firebase.assertFails(studentAnswerRef.update({
        teacherInfo: "should not work"
      }));
    });
  });
});
