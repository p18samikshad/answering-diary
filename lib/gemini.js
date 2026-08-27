// Gemini wrapper — all calls are server-side. Key comes from Secret Manager (see secrets.js).
// Vocabulary note: the product is an enchanted diary, so the data contract uses its language —
// a saved session is a "memory", its emotional register a "humour", its tags "threads".
import { GoogleGenAI } from "@google/genai";
import { getGeminiApiKey } from "./secrets.js";

const CHAT_MODEL = process.env.GEMINI_CHAT_MODEL || "gemini-2.5-flash";
const EMBED_MODEL = process.env.GEMINI_EMBED_MODEL || "gemini-embedding-001";

let clientPromise = null;
async function getClient() {
  if (!clientPromise) {
    clientPromise = getGeminiApiKey()
      .then((apiKey) => new GoogleGenAI({ apiKey }))
      .catch((e) => { clientPromise = null; throw e; });
  }
  return clientPromise;
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

  const res = await ai.models.generateContent({
    model: CHAT_MODEL,
    contents,
    config: { systemInstruction: SYSTEM_INSTRUCTION, temperature: 0.8 },
  });
  return (res.text || "").trim();
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

  const res = await ai.models.generateContent({
    model: CHAT_MODEL,
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    config: { responseMimeType: "application/json", temperature: 0.3 },
  });

  try {
    const parsed = JSON.parse(res.text);
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
      summary: (res.text || "").slice(0, 1200),
      humour: "neutral",
      humourScore: 5,
      threads: [],
      resolutions: [],
    };
  }
}

// Embedding vector — lets the diary recall by meaning rather than by keyword.
export async function embed(text) {
  const ai = await getClient();
  const res = await ai.models.embedContent({
    model: EMBED_MODEL,
    contents: String(text).slice(0, 8000),
  });
  return res.embeddings?.[0]?.values || [];
}

// Weekly reflection, delivered as Owl Post.
export async function owlPost(memories) {
  const ai = await getClient();
  const prompt =
    "Below are this week's journal summaries with their emotional readings. Write a warm weekly " +
    "reflection (120-180 words) that names emotional patterns, celebrates one win, and offers two " +
    "gentle prompts for next week. Return ONLY JSON: { \"reflection\": string, \"prompts\": string[2] }\n\n" +
    JSON.stringify(memories).slice(0, 18000);

  const res = await ai.models.generateContent({
    model: CHAT_MODEL,
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    config: { responseMimeType: "application/json", temperature: 0.6 },
  });
  try {
    const p = JSON.parse(res.text);
    return { reflection: String(p.reflection || "").slice(0, 2000), prompts: (p.prompts || []).slice(0, 2).map(String) };
  } catch {
    return { reflection: (res.text || "").slice(0, 2000), prompts: [] };
  }
}

// A prompt the diary whispers, drawn from the user's own recent threads.
export async function whisper(recentThreads) {
  const ai = await getClient();
  const res = await ai.models.generateContent({
    model: CHAT_MODEL,
    contents: [{ role: "user", parts: [{ text:
      "Write ONE short, specific journaling prompt (<=20 words) inspired by these recent themes: " +
      (recentThreads.join(", ") || "everyday life") + ". Return only the prompt text." }] }],
    config: { temperature: 0.9 },
  });
  return (res.text || "What is on your mind tonight?").trim().replace(/^["']|["']$/g, "");
}

function clampInt(v, min, max, dflt) {
  const n = parseInt(v, 10);
  if (Number.isNaN(n)) return dflt;
  return Math.max(min, Math.min(max, n));
}
