// Unit test for the model fallback chain.
// Run: node --experimental-test-module-mocks --test test/fallback.test.mjs
import { test, mock } from "node:test";
import assert from "node:assert/strict";

// --- stub the two things gemini.js reaches for -----------------------------
const calls = [];        // every model the chain actually tried, in order
let behaviour = () => {}; // per-test: throw for some models, answer for others

mock.module("../lib/secrets.js", {
  namedExports: { getGeminiApiKey: async () => "fake-key" },
});

mock.module("@google/genai", {
  namedExports: {
    GoogleGenAI: class {
      constructor() {
        this.models = {
          generateContent: async ({ model }) => {
            calls.push(model);
            return behaviour(model) ?? { text: `answered by ${model}` };
          },
          embedContent: async ({ model }) => {
            calls.push(model);
            behaviour(model);
            return { embeddings: [{ values: [0.1, 0.2] }] };
          },
        };
      }
    },
  },
});

process.env.GEMINI_CHAT_MODELS = "model-a,model-b,model-c";
process.env.GEMINI_EMBED_MODELS = "embed-a,embed-b";
const { inscribe, embed, whisper, modelChain } = await import("../lib/gemini.js");

const reset = () => { calls.length = 0; behaviour = () => {}; };
const quota = new Error("429 RESOURCE_EXHAUSTED: quota exceeded for this model");
const fatal = new Error("400 INVALID_ARGUMENT: malformed request");

test("chain is parsed from the plural env var, in order", () => {
  assert.deepEqual(modelChain().chat, ["model-a", "model-b", "model-c"]);
  assert.deepEqual(modelChain().embed, ["embed-a", "embed-b"]);
});

test("first model answers -> no fallback, one call", async () => {
  reset();
  const out = await inscribe([], "hello");
  assert.equal(out, "answered by model-a");
  assert.deepEqual(calls, ["model-a"]);
});

test("exhausted model is skipped, next one serves", async () => {
  reset();
  behaviour = (m) => { if (m === "model-a") throw quota; };
  const out = await inscribe([], "hello");
  assert.equal(out, "answered by model-b");
  assert.deepEqual(calls, ["model-a", "model-b"]);
});

test("two exhausted models -> third serves", async () => {
  reset();
  behaviour = (m) => { if (m !== "model-c") throw quota; };
  const out = await inscribe([], "hello");
  assert.equal(out, "answered by model-c");
  assert.deepEqual(calls, ["model-a", "model-b", "model-c"]);
});

test("a retired model ('no longer available') is treated as skippable", async () => {
  reset();
  behaviour = (m) => {
    if (m === "model-a") throw new Error("404 NOT_FOUND: model is no longer available to new users");
  };
  assert.equal(await inscribe([], "hi"), "answered by model-b");
});

test("a real fault stops the chain immediately (no quota burned downstream)", async () => {
  reset();
  behaviour = () => { throw fatal; };
  await assert.rejects(() => inscribe([], "hello"), /INVALID_ARGUMENT/);
  assert.deepEqual(calls, ["model-a"], "must not retry other models on a genuine error");
});

test("all models exhausted -> the last error surfaces", async () => {
  reset();
  behaviour = () => { throw quota; };
  await assert.rejects(() => inscribe([], "hello"), /RESOURCE_EXHAUSTED/);
  assert.deepEqual(calls, ["model-a", "model-b", "model-c"]);
});

test("embed() degrades to [] rather than blocking a seal", async () => {
  reset();
  behaviour = () => { throw quota; };
  assert.deepEqual(await embed("text"), []);
  assert.deepEqual(calls, ["embed-a", "embed-b"]);
});

test("embed() falls back to the second embedding model when it can", async () => {
  reset();
  behaviour = (m) => { if (m === "embed-a") throw quota; };
  assert.deepEqual(await embed("text"), [0.1, 0.2]);
});

test("whisper() returns a written prompt when every model is exhausted", async () => {
  reset();
  behaviour = () => { throw quota; };
  const w = await whisper(["work", "sleep"]);
  assert.equal(typeof w, "string");
  assert.ok(w.length > 10, "must still hand the user a prompt");
});
