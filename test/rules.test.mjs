// =============================================================================
//  The isolation requirement, proved rather than asserted.
//
//  "Zero cross-user leakage" is the one claim a journal cannot afford to get
//  wrong, and it is also the easiest to *say*. These tests run firestore.rules
//  against the Firestore emulator and assert that Ginny cannot reach a single
//  document belonging to Tom -- not by reading it, not by listing the
//  collection, not by writing into his subtree, not by forging the uid field.
//
//  The rules are the last line of defence: they hold even if every line of
//  application code is wrong. So they are tested independently of it.
//
//  Run:  npm run test:rules      (starts the emulator itself)
// =============================================================================
import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, deleteDoc, collection, getDocs } from "firebase/firestore";
import { readFileSync } from "node:fs";

const TOM = "tom-riddle-uid";
const GINNY = "ginny-weasley-uid";

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "answering-diary-rules-test",
    firestore: {
      rules: readFileSync("firestore.rules", "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });
});

after(async () => { if (env) await env.cleanup(); });

// Seed one memory owned by Tom, with rules bypassed, before every test.
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${TOM}/memories/m1`), {
      uid: TOM,
      title: "A private memory",
      summary: "Nobody else should ever read this.",
    });
    await setDoc(doc(db, `users/${TOM}/owlpost/w1`), { uid: TOM, reflection: "private" });
  });
});

const asTom = () => env.authenticatedContext(TOM).firestore();
const asGinny = () => env.authenticatedContext(GINNY).firestore();
const asStranger = () => env.unauthenticatedContext().firestore();

// --- the owner keeps working ------------------------------------------------

test("the owner can read their own memory", async () => {
  await assertSucceeds(getDoc(doc(asTom(), `users/${TOM}/memories/m1`)));
});

test("the owner can list their own memories", async () => {
  await assertSucceeds(getDocs(collection(asTom(), `users/${TOM}/memories`)));
});

test("the owner can create a memory carrying their own uid", async () => {
  await assertSucceeds(
    setDoc(doc(asTom(), `users/${TOM}/memories/m2`), { uid: TOM, title: "Another" })
  );
});

// --- the whole point --------------------------------------------------------

test("a second user CANNOT read the first user's memory", async () => {
  await assertFails(getDoc(doc(asGinny(), `users/${TOM}/memories/m1`)));
});

test("a second user CANNOT list the first user's memories", async () => {
  // Listing is the leak that per-document checks miss: denying `get` but allowing
  // `list` would hand over every title in the collection.
  await assertFails(getDocs(collection(asGinny(), `users/${TOM}/memories`)));
});

test("a second user CANNOT write into the first user's subtree", async () => {
  await assertFails(
    setDoc(doc(asGinny(), `users/${TOM}/memories/m3`), { uid: GINNY, title: "planted" })
  );
});

test("a second user CANNOT overwrite the first user's memory", async () => {
  await assertFails(
    setDoc(doc(asGinny(), `users/${TOM}/memories/m1`), { uid: TOM, title: "tampered" })
  );
});

test("a second user CANNOT delete the first user's memory", async () => {
  await assertFails(deleteDoc(doc(asGinny(), `users/${TOM}/memories/m1`)));
});

test("a second user CANNOT read the first user's weekly reflection", async () => {
  await assertFails(getDoc(doc(asGinny(), `users/${TOM}/owlpost/w1`)));
});

test("a second user CANNOT read the first user's root document", async () => {
  await assertFails(getDoc(doc(asGinny(), `users/${TOM}`)));
});

// --- forgery ----------------------------------------------------------------

test("a user CANNOT create a memory stamped with someone else's uid", async () => {
  // Anti-tampering: the document's own uid field must match the token, so a
  // forged author cannot be smuggled in even inside your own subtree.
  await assertFails(
    setDoc(doc(asGinny(), `users/${GINNY}/memories/m4`), { uid: TOM, title: "forged author" })
  );
});

// --- unauthenticated --------------------------------------------------------

test("an unauthenticated caller can read nothing", async () => {
  await assertFails(getDoc(doc(asStranger(), `users/${TOM}/memories/m1`)));
});

test("an unauthenticated caller can write nothing", async () => {
  await assertFails(setDoc(doc(asStranger(), `users/${TOM}/memories/m5`), { uid: TOM }));
});

// --- the default-deny baseline ---------------------------------------------

test("collections outside users/{uid} are denied even to a signed-in user", async () => {
  await assertFails(getDoc(doc(asTom(), "admin/config")));
  await assertFails(setDoc(doc(asTom(), "anything/else"), { x: 1 }));
});
