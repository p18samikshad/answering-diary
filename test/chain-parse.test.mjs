// The deploy scripts write the chain with SEMICOLONS, because `gcloud run deploy
// --set-env-vars` treats a comma as the separator between variables. If the parser
// ever stops accepting semicolons, every deploy silently ships a one-model "chain"
// whose single name is "a;b;c" — and the first quota error becomes an outage again.
import { test, mock } from "node:test";
import assert from "node:assert/strict";

mock.module("../lib/secrets.js", { namedExports: { getGeminiApiKey: async () => "k" } });
mock.module("@google/genai", { namedExports: { GoogleGenAI: class { constructor() { this.models = {}; } } } });

process.env.GEMINI_CHAT_MODELS = "gemini-2.5-flash-lite;gemini-2.5-flash;gemini-3.6-flash";
process.env.GEMINI_EMBED_MODELS = "gemini-embedding-001";
// A stale singular var left on the service must NOT be able to pin the chain to the
// exhausted model it names.
process.env.GEMINI_CHAT_MODEL = "gemini-3.6-flash";

const { modelChain } = await import("../lib/gemini.js");

test("semicolon-separated chain parses into three models", () => {
  assert.deepEqual(modelChain().chat, [
    "gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-3.6-flash",
  ]);
});

test("an explicit chain overrides a leftover singular env var", () => {
  assert.equal(modelChain().chat[0], "gemini-2.5-flash-lite");
});

test("embed chain parses", () => {
  assert.deepEqual(modelChain().embed, ["gemini-embedding-001"]);
});
