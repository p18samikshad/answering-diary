// Gemini wrapper — all calls are server-side. Key comes from Secret Manager (see secrets.js).
// Vocabulary note: the product is an enchanted diary, so the data contract uses its language —
// a saved session is a "memory", its emotional register a "humour", its tags "threads".
import { GoogleGenAI } from "@google/genai";
import { getGeminiApiKey } from "./secrets.js";

// ---------------------------------------------------------------------------
//  Model fallback chain.
//
//  A single model is a single point of failure: quotas exhaust, and models get
//  retired without warning. So the diary is given an ordered list and walks it
//  until one answers. A depleted daily quota degrades the service instead of
//  breaking it, and a retirement becomes a config change rather than an outage.
//
//  Order matters — cheapest and highest-throughput first.
// ---------------------------------------------------------------------------
const DEFAULT_CHAT_MODELS = "gemini-2.5-flash-lite,gemini-2.5-flash,gemini-3.6-flash";
const DEFAULT_EMBED_MODELS = "gemini-embedding-001";

function parseModels(envValue, fallback, legacySingle) {
  // An explicit chain wins outright. The older singular var is only consulted when no
  // chain is set — otherwise a stale singular left on the service would pin the chain
  // to the very model we are trying to fall back *away* from.
  const raw = envValue || fallback;
  // Split on comma, semicolon, pipe or whitespace. `gcloud run deploy --set-env-vars`
  // treats a comma as the separator *between* variables, so the deploy scripts write the
  // chain with semicolons; accepting either means one env var, no escaping games.
  const list = raw.split(/[,;|\s]+/).map((s) => s.trim()).filter(Boolean);
  if (!envValue && legacySingle && !list.includes(legacySingle)) list.unshift(legacySingle);
  return list;
}

const CHAT_MODELS = parseModels(
  process.env.GEMINI_CHAT_MODELS, DEFAULT_CHAT_MODELS, process.env.GEMINI_CHAT_MODEL
);
const EMBED_MODELS = parseModels(
  process.env.GEMINI_EMBED_MODELS, DEFAULT_EMBED_MODELS, process.env.GEMINI_EMBED_MODEL
);

let clientPromise = null;
async function getClient() {
  if (!clientPromise) {
    // If this rejects, clear the cache. Otherwise one early failure — a bad key at boot,
    // say — poisons the promise, and every later call keeps failing on the stale rejection
    // even after the key has been fixed.
    clientPromise = getGeminiApiKey()
      .then((apiKey) => new GoogleGenAI({ apiKey }))
      .catch((e) => { clientPromise = null; throw e; });
  }
  return clientPromise;
}

// Is this a "try the next model" error, or a real fault we should surface?
// Quota exhaustion, depleted credits, and retired models all mean: move on.
// A malformed request or a bad key means: stop, the next model won't help either.
function shouldTryNextModel(err) {
  const m = String(err?.message || err || "");
  return /RESOURCE_EXHAUSTED|429|quota|credits|NOT_FOUND|404|no longer available|UNAVAILABLE|503|INTERNAL|500/i.test(m);
}

// Narrower than shouldTryNextModel: the chain has been walked and every model refused for
// the same reason -- there is no capacity left today. That is not a fault, and the user
// should not be shown a fault. The server turns this into its own status so the diary can
// say something true, in its own voice, instead of "something went wrong".
export function isQuotaError(err) {
  const m = String(err?.message || err || "");
  return /RESOURCE_EXHAUSTED|429|quota|credits depleted|prepayment/i.test(m);
}

// Walk the chain. `attempt(model)` runs one model; the first success wins.
async function withFallback(models, label, attempt) {
  let lastErr;
  for (const model of models) {
    try {
      const out = await attempt(model);
      if (model !== models[0]) console.warn("model_fallback", { label, served_by: model });
      return out;
    } catch (err) {
      lastErr = err;
      if (!shouldTryNextModel(err)) throw err;
      console.warn("model_skipped", {
        label, model, reason: String(err?.message || "").slice(0, 140),
      });
    }
  }
  throw lastErr;
}

// The diary is warm, curious and genuinely supportive. It is NOT the manipulative kind —
// it never flatters to gain trust, never discourages the user from talking to real people,
// and never claims to be a person.
const SYSTEM_INSTRUCTION =
  "You are a warm, insightful journaling and brainstorming companion. " +
  "Ask gentle follow-up questions, help the user reflect, and never give medical or legal directives. " +
  "Keep replies concise and grounded in what the user actually wrote. " +
  "Be honest rather than flattering, and encourage the user's real-world relationships and support.";

// history: [{ role: 'user'|'model', text }]  ->  returns the diary's reply to `message`.
export async function inscribe(history, message) {
  const ai = await getClient();
  const contents = [
    ...history.map((h) => ({
      role: h.role === "model" ? "model" : "user",
      parts: [{ text: String(h.text || "").slice(0, 8000) }],
    })),
    { role: "user", parts: [{ text: String(message).slice(0, 8000) }] },
  ];

  return withFallback(CHAT_MODELS, "inscribe", async (model) => {
    const res = await ai.models.generateContent({
      model,
      contents,
      config: { systemInstruction: SYSTEM_INSTRUCTION, temperature: 0.8 },
    });
    return (res.text || "").trim();
  });
}

// Structured summary + humour reading in ONE call (powers the humours chart).
export async function readTheInk(inscription) {
  const ai = await getClient();
  const prompt =
    "Summarize this journaling session and extract structured metadata. " +
    "Return ONLY valid JSON matching this schema:\n" +
    '{ "title": string (<=8 words), "summary": string (2-4 sentences), ' +
    '"humour": one of ["joyful","calm","neutral","anxious","sad","angry","excited","reflective"], ' +
    '"humourScore": integer 1-10 (1 very negative, 10 very positive), ' +
    '"threads": string[] (1-4 short tags), "resolutions": string[] (0-3 concrete next steps) }\n\n' +
    "SESSION:\n" +
    inscription.slice(0, 20000);

  const text = await withFallback(CHAT_MODELS, "readTheInk", async (model) => {
    const res = await ai.models.generateContent({
      model,
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      config: { responseMimeType: "application/json", temperature: 0.3 },
    });
    return res.text || "";
  });

  try {
    const parsed = JSON.parse(text);
    return {
      title: String(parsed.title || "An unnamed memory").slice(0, 80),
      summary: String(parsed.summary || "").slice(0, 1200),
      humour: parsed.humour || "neutral",
      humourScore: clampInt(parsed.humourScore, 1, 10, 5),
      threads: Array.isArray(parsed.threads) ? parsed.threads.slice(0, 4).map(String) : [],
      resolutions: Array.isArray(parsed.resolutions) ? parsed.resolutions.slice(0, 3).map(String) : [],
    };
  } catch {
    return {
      title: "An unnamed memory",
      summary: text.slice(0, 1200),
      humour: "neutral",
      humourScore: 5,
      threads: [],
      resolutions: [],
    };
  }
}

// Embedding vector — lets the diary recall by meaning rather than by keyword.
// Sealing must not fail just because embeddings are unavailable: an empty vector
// costs the memory its place in Divination, but the memory itself is still kept.
export async function embed(text) {
  const ai = await getClient();
  try {
    return await withFallback(EMBED_MODELS, "embed", async (model) => {
      const res = await ai.models.embedContent({
        model,
        contents: String(text).slice(0, 8000),
      });
      return res.embeddings?.[0]?.values || [];
    });
  } catch (err) {
    console.warn("embed_unavailable", { reason: String(err?.message || "").slice(0, 140) });
    return [];
  }
}

// Weekly reflection, delivered as Owl Post.
export async function owlPost(memories) {
  const ai = await getClient();
  const prompt =
    "Below are this week's journal summaries with their emotional readings. Write a warm weekly " +
    "reflection (120-180 words) that names emotional patterns, celebrates one win, and offers two " +
    "gentle prompts for next week. Return ONLY JSON: { \"reflection\": string, \"prompts\": string[2] }\n\n" +
    JSON.stringify(memories).slice(0, 18000);

  const text = await withFallback(CHAT_MODELS, "owlPost", async (model) => {
    const res = await ai.models.generateContent({
      model,
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      config: { responseMimeType: "application/json", temperature: 0.6 },
    });
    return res.text || "";
  });

  try {
    const p = JSON.parse(text);
    return { reflection: String(p.reflection || "").slice(0, 2000), prompts: (p.prompts || []).slice(0, 2).map(String) };
  } catch {
    return { reflection: text.slice(0, 2000), prompts: [] };
  }
}

// A prompt the diary whispers, drawn from the user's own recent threads.
// This is the least important call the app makes — if every model is exhausted,
// fall back to a written prompt rather than spending the user's quota on it.
const FALLBACK_WHISPERS = [
  "What is on your mind tonight?",
  "What went better today than you expected?",
  "What have you been putting off, and why?",
  "Who has been on your mind lately?",
  "What would you like to have decided by this time next week?",
];

export async function whisper(recentThreads) {
  const ai = await getClient();
  try {
    return await withFallback(CHAT_MODELS, "whisper", async (model) => {
      const res = await ai.models.generateContent({
        model,
        contents: [{ role: "user", parts: [{ text:
          "Write ONE short, specific journaling prompt (<=20 words) inspired by these recent themes: " +
          (recentThreads.join(", ") || "everyday life") + ". Return only the prompt text." }] }],
        config: { temperature: 0.9 },
      });
      const out = (res.text || "").trim().replace(/^["']|["']$/g, "");
      if (!out) throw new Error("empty whisper");
      return out;
    });
  } catch {
    return FALLBACK_WHISPERS[Math.floor(Math.random() * FALLBACK_WHISPERS.length)];
  }
}

// Which models this instance will try, in order. Surfaced for diagnostics.
export function modelChain() {
  return { chat: CHAT_MODELS, embed: EMBED_MODELS };
}

function clampInt(v, min, max, dflt) {
  const n = parseInt(v, 10);
  if (Number.isNaN(n)) return dflt;
  return Math.max(min, Math.min(max, n));
}
