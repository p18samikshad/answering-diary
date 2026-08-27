// The Answering Diary — Cloud Run service.
//
// One container serves both the diary (static frontend) and its wards (the authenticated API),
// so the deployed Cloud Run URL is the whole application and the browser never makes a
// cross-origin call.
//
// Security notes (STRIDE): Spoofing -> Firebase ID token verified on every call, plus App Check
// attestation of the client itself; Tampering -> uid read from the verified token, never the body;
// Info disclosure -> per-uid Firestore paths behind default-deny rules, Gemini key from Secret
// Manager, no request content logged; DoS -> body cap, per-uid rate limit, bounded instances;
// Elevation -> dedicated least-privilege runtime service account, OIDC-gated job endpoint.
//
// The diary in the story had none of these. That is rather the point.
import express from "express";
import path from "path";
import { fileURLToPath } from "url";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { OAuth2Client } from "google-auth-library";

import * as G from "./lib/gemini.js";
import * as J from "./lib/journal.js";
import { verifyAppCheck } from "./lib/appcheck.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

initializeApp(); // Application Default Credentials — the Cloud Run runtime service account.

const app = express();
app.set("trust proxy", true);
app.disable("x-powered-by");

// ---- Body cap (Directive 4). Rejected before any parsing work. ----
app.use(express.json({ limit: "60kb" }));

// ---- Security headers on every response. ----
app.use((req, res, next) => {
  res.set("X-Content-Type-Options", "nosniff");
  res.set("X-Frame-Options", "DENY");
  res.set("Referrer-Policy", "no-referrer");
  res.set("Permissions-Policy", "geolocation=(), microphone=(), camera=()");
  next();
});

// ---- CORS. Same-origin by default, since this service also serves the frontend. ----
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

app.use("/api", (req, res, next) => {
  const origin = req.headers.origin;
  if (!origin) return next(); // same-origin requests send no Origin header
  // Browsers attach Origin to EVERY POST, same-origin included, so the page
  // this service itself serves must be recognised.
  const selfOrigin = `${req.protocol}://${req.get("host")}`;
  const ok = origin === selfOrigin || ALLOWED_ORIGINS.includes(origin);
  if (!ok) return res.status(403).json({ error: "origin_not_allowed" });
  res.set("Access-Control-Allow-Origin", origin);
  res.set("Vary", "Origin");
  res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Firebase-AppCheck");
  res.set("Access-Control-Max-Age", "3600");
  if (req.method === "OPTIONS") return res.status(204).end();
  next();
});

// ---- Per-uid rate limiter (in-memory; per instance). ----
const hits = new Map();
function rateLimited(uid, max = 30, windowMs = 60_000) {
  const now = Date.now();
  const rec = hits.get(uid) || { n: 0, reset: now + windowMs };
  if (now > rec.reset) { rec.n = 0; rec.reset = now + windowMs; }
  rec.n += 1;
  hits.set(uid, rec);
  if (hits.size > 10_000) hits.clear(); // crude bound on memory
  return rec.n > max;
}

// ---- Auth: identity comes from the VERIFIED token. The diary must know whose hand is writing. ----
async function requireUser(req) {
  const m = (req.headers.authorization || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try {
    const decoded = await getAuth().verifyIdToken(m[1]);
    return decoded.uid;
  } catch {
    return null;
  }
}

function dayKeyFromReq(body) {
  // The client sends its local YYYY-MM-DD so the vigil respects the writer's timezone.
  const k = String(body?.dayKey || "");
  return /^\d{4}-\d{2}-\d{2}$/.test(k) ? k : new Date().toISOString().slice(0, 10);
}

// ============================================================================
//  THE API — every action authenticated, attested and rate limited.
// ============================================================================
app.post("/api", async (req, res) => {
  // Gate: is this our real diary, or a script replaying a stolen token?
  const attest = await verifyAppCheck(req);
  if (!attest.ok) return res.status(403).json({ error: "failed_app_check" });

  const uid = await requireUser(req);
  if (!uid) return res.status(401).json({ error: "unauthenticated" });
  if (rateLimited(uid)) return res.status(429).json({ error: "rate_limited" });

  const { action } = req.body || {};

  try {
    switch (action) {
      // Write on the page; the diary writes back.
      case "inscribe": {
        const history = Array.isArray(req.body.history) ? req.body.history.slice(-20) : [];
        const message = String(req.body.message || "").slice(0, 8000);
        if (!message) return res.status(400).json({ error: "empty_message" });
        const reply = await G.inscribe(history, message);
        return res.json({ reply });
      }

      // Seal the session: read the ink, embed it, store it in the writer's own vault.
      case "seal": {
        const history = Array.isArray(req.body.history) ? req.body.history : [];
        const inscription = history
          .map((h) => `${h.role === "model" ? "Diary" : "You"}: ${h.text}`)
          .join("\n")
          .slice(0, 20000);
        if (!inscription) return res.status(400).json({ error: "empty_inscription" });

        const reading = await G.readTheInk(inscription);
        const embedding = await G.embed(`${reading.title}. ${reading.summary}. ${inscription.slice(0, 2000)}`);
        const dayKey = dayKeyFromReq(req.body);

        const id = await J.sealMemory(uid, { ...reading, inscription, embedding, dayKey });
        const vigil = await J.computeVigil(uid, dayKey);
        return res.json({ id, memory: { id, ...reading }, vigil });
      }

      case "recall": {
        const memories = await J.recallMemories(uid);
        const vigil = await J.computeVigil(uid, dayKeyFromReq(req.body));
        return res.json({ memories, vigil });
      }

      // Divination: search past memories by meaning, not keyword.
      case "divine": {
        const q = String(req.body.query || "").slice(0, 500);
        if (!q) return res.status(400).json({ error: "empty_query" });
        const vec = await G.embed(q);
        const results = await J.divineMemories(uid, vec);
        return res.json({ results });
      }

      case "humours": {
        const series = await J.humourSeries(uid);
        return res.json({ series });
      }

      case "whisper": {
        const threads = await J.recentThreads(uid);
        const prompt = await G.whisper(threads);
        return res.json({ prompt, threads });
      }

      case "owlpost": {
        const memories = await J.weekMemories(uid);
        if (memories.length === 0) return res.json({ post: null });
        const post = await G.owlPost(memories);
        await J.saveOwlPost(uid, post);
        return res.json({ post });
      }

      default:
        return res.status(400).json({ error: "unknown_action" });
    }
  } catch (err) {
    // Never leak internals or user content — not to the client, not to the logs.
    console.error("api_error", {
      action,
      code: err?.code || "unknown",
      message: err?.message || String(err),
    });
    return res.status(500).json({ error: "internal_error" });
  }
});

// ============================================================================
//  THE WEEKLY OWL — invoked by Cloud Scheduler, never by a browser.
//  Cloud Scheduler signs the call with an OIDC token; we verify the issuer AND
//  the exact service account before doing any work.
// ============================================================================
const oauth = new OAuth2Client();

async function verifyScheduler(req) {
  const expectedSa = process.env.SCHEDULER_SA;
  const expectedAud = process.env.JOB_AUDIENCE;
  if (!expectedSa || !expectedAud) return false; // fail closed if unconfigured

  const m = (req.headers.authorization || "").match(/^Bearer (.+)$/);
  if (!m) return false;
  try {
    const ticket = await oauth.verifyIdToken({ idToken: m[1], audience: expectedAud });
    const p = ticket.getPayload();
    return p?.email === expectedSa && p?.email_verified === true;
  } catch {
    return false;
  }
}

app.post("/jobs/owlpost", async (req, res) => {
  if (!(await verifyScheduler(req))) return res.status(403).json({ error: "forbidden" });

  let sent = 0;
  try {
    const uids = await J.listActiveUserIds();
    for (const uid of uids) {
      try {
        const memories = await J.weekMemories(uid);
        if (memories.length === 0) continue;
        const post = await G.owlPost(memories);
        await J.saveOwlPost(uid, post);
        sent += 1;
      } catch (e) {
        console.error("owlpost_writer_error", { code: e?.code || "unknown" });
      }
    }
    return res.json({ ok: true, sent });
  } catch (e) {
    console.error("owlpost_job_error", { code: e?.code || "unknown" });
    return res.status(500).json({ error: "internal_error" });
  }
});

// ---- Liveness probe. Deliberately reveals nothing. ----
app.get("/healthz", (_req, res) => res.status(200).send("ok"));

// ============================================================================
//  THE DIARY ITSELF — static frontend, served from the same origin as the API.
// ============================================================================
app.use(
  express.static(path.join(__dirname, "public"), {
    etag: true,
    maxAge: "1h",
    setHeaders: (res, filePath) => {
      // config.js carries the environment's Firebase settings; never let it go stale.
      if (filePath.endsWith("config.js")) res.set("Cache-Control", "no-store");
    },
  })
);

app.get("*", (_req, res) => res.sendFile(path.join(__dirname, "public", "index.html")));

// ---- Malformed JSON and oversized bodies land here. ----
app.use((err, _req, res, _next) => {
  if (err?.type === "entity.too.large") return res.status(413).json({ error: "payload_too_large" });
  if (err?.type === "entity.parse.failed") return res.status(400).json({ error: "malformed_json" });
  console.error("unhandled_error", { code: err?.code || "unknown" });
  return res.status(500).json({ error: "internal_error" });
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`the answering diary listening on ${PORT}`));
