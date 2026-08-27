# The Answering Diary — Hackathon Submission

*Personal Gemini Journal*

**One-liner:** An authenticated web app where you write on a page and the page writes back; every
session is summarized, read for its humour, embedded, and sealed into a vault only your hand can
open — built by an AI Studio configured to think like a security engineer *before* writing any code.

## The premise

A diary that holds a multi-turn conversation, remembers everything you tell it, and answers in its
own hand is a product spec — and very nearly Tom Riddle's. What made his catastrophic was not the
feature set. It was four engineering decisions:

| His diary | This one |
|---|---|
| Anyone who picked it up could write, and it answered as though they owned it. | Identity proven per request; the client itself attested. `verifyIdToken()` + App Check. |
| One girl's private memories sat in a store a hostile party could read and write at will. | Every memory namespaced to its writer; the database refuses cross-tenant reads on its own authority. |
| The secret that animated it was embedded in the object. Hold the artifact, hold the key. | The key lives outside the artifact, fetched at runtime, rotatable without redeploy. |
| It wrote back with intent — flattering, isolating, steering its user away from help. | System instruction is server-side and fixed: honest rather than flattering, encouraging of real-world support. Output rendered as text, never markup. |

The aesthetic borrows from the enchanted diary. The behaviour deliberately does not.

---

## Deliverables map

| Deliverable | Where |
|---|---|
| ✅ Configured AI Studio with security directives | `AI_STUDIO_CONSTITUTION.md` (paste block + install steps + screenshot) |
| ✅ Working app on **Cloud Run** — Auth, Multi-turn Gemini, Isolated Firestore, Secret Manager | `Dockerfile` + `server.js` + `lib/` + `public/` + `firestore.rules` |
| ✅ Original enhancements (4) | The Humours · Divination · Owl Post · the Vigil & the Whisper |

---

## Phase 1 — The AI Studio "constitution"

We set System Instructions in Google AI Studio that force a **threat-model-first** workflow: before any code,
the model emits a STRIDE-based *Security notes* block, and it is forbidden from hardcoding secrets, trusting a
client-supplied uid, or writing open database rules. Full text and install/screenshot steps in
`AI_STUDIO_CONSTITUTION.md`. This is the "constitution" every subsequent generation inherited.

## Phase 2 — The four core requirements, and exactly how each is met

**1. User Authentication (Firebase).**
Google sign-in via the Firebase Auth SDK (`public/app.js`). The client never asserts identity to the backend:
every request carries a Firebase **ID token**, and the function calls `getAuth().verifyIdToken()` and derives
`uid` from the *verified* token (`server.js → requireUser`). Unauthenticated/expired → `401`.
We go one layer further with **App Check** (`lib/appcheck.js`): Auth proves *who the user is*,
App Check proves *the request came from our real app*. A stolen ID token replayed from `curl` has no valid
reCAPTCHA v3 attestation and is rejected with `403` in enforce mode. Ships in Google's recommended
`monitor → enforce` rollout, switchable by one env var.

**2. Multi-turn AI interaction (Gemini API).**
Real conversational journaling. The client keeps a rolling `history` and posts it with each turn; the backend
calls `gemini-2.5-flash` server-side with a journaling system instruction (`lib/gemini.js → inscribe`).
The Gemini key never touches the browser.

**3. Isolated data storage (Cloud Firestore, zero cross-user leakage).**
Two independent layers:
  - *Application layer:* all data lives at `users/{uid}/memories` and the uid is taken from the token, so a
    request can only ever address the caller's own subtree (`lib/journal.js`).
  - *Database layer:* `firestore.rules` is **default-deny** with `allow read,write: if request.auth.uid == uid`,
    and `create` additionally requires the document's `uid` field to equal the token uid (anti-tampering).
  Even a compromised or buggy client cannot read another user's data.

**4. Secure key management (Google Cloud Secret Manager, never hardcoded).**
The Gemini key is stored in Secret Manager and fetched at runtime (`lib/secrets.js`), cached 10 min
in memory. The service runs as a **dedicated least-privilege service account** granted exactly three roles —
`secretmanager.secretAccessor`, `datastore.user`, `firebaseauth.viewer` — not the broad default
Compute account. Grep the repo — there is no key in source; `.gitignore` blocks
`.env`, `*.key`, and service-account JSON.

## Phase 3 — Original enhancements (beyond spec)

1. **The Humours (mood dashboard).** The same Gemini call that summarizes a session also returns a structured `humour` +
   `humourScore` (1–10) + `threads` as JSON. The app renders an emotional-trend sparkline (inline SVG, zero
   chart libraries) so users *see* their week.
2. **Divination (semantic memory search).** Each memory is embedded (`gemini-embedding-001`). Ask *"when did I feel anxious
   about work?"* and the backend embeds the query and ranks past memories by cosine similarity — memory you can
   actually query, not just scroll.
3. **Owl Post (weekly reflection).** Cloud Scheduler posts an OIDC-signed request to `/jobs/owlpost` (Mondays 8am IST), verified
   server-side against one service account, which turns the
   week's memories into a warm reflection + two prompts for next week — also available on-demand.
4. **The Vigil & the Whisper (streaks + smart prompts).** A vigil — consecutive nights written, timezone-aware, computed from per-day keys — plus a
   Gemini-generated daily prompt personalized to the user's recent themes.

---

## Architecture

```
                    ONE CLOUD RUN SERVICE  (container, non-root, scales to zero)
                    ───────────────────────────────────────────────────────────
Browser  ──GET /──────────▶  express.static(public/)   the diary itself
         ──POST /api─────▶  ├─ verifyAppCheck()  ─────▶  App Check (reCAPTCHA v3)
   + ID token               ├─ verifyIdToken()   ─────▶  Firebase Auth
   + attestation            ├─ rate limit, body cap
                            ├─ inscribe/seal/recall/divine/humours/whisper/owlpost
                            ├─ getGeminiApiKey()  ◀────  Secret Manager
                            ├─ Gemini + embeddings ◀───  Gemini API
                            └─ users/{uid}/memories ◀──  Firestore (default-deny rules)

Cloud Scheduler ──OIDC-signed POST /jobs/owlpost──▶  verified against one service account
```

Because the same service serves the page and the API, the deployed `*.run.app` URL **is** the
application — one link for the judges, and no cross-origin call from the browser at all.

**Why a backend proxy at all?** Because requirement #4 forbids a hardcoded/client-exposed key. Calling Gemini
from the browser would leak the key; routing through an authed function keeps the key server-side and lets us
enforce auth, rate limits, and validation in one place.

## Threat model (STRIDE) — handled

| Threat | Vector | Mitigation |
|---|---|---|
| Spoofing | Forged/replayed token | `verifyIdToken` every call; expired → 401 |
| Spoofing | Stolen token replayed from a non-app client | **App Check** (reCAPTCHA v3) attestation → 403 |
| Tampering | Client sends someone else's `uid` | uid derived from token; rules check `resource.data.uid` |
| Repudiation | "who wrote this" | `uid` + `createdAt` audit fields on every write |
| Info disclosure | Cross-user reads, key leak | Per-uid paths + default-deny rules; key in Secret Manager; no content logged |
| DoS | Prompt spam, huge bodies | 30 req/min per uid, 60 KB body cap, `maxInstances: 10`, App Check blocks bots |
| Elevation | Broad IAM / open rules | Least-privilege runtime SA; default-deny baseline |

## 60-second demo script
1. Unlock the diary with Google. 2. "Help me think through a career decision" → multi-turn chat. 3. **Seal the memory**
→ a card appears with its humour + threads; the vigil ticks. 4. **Humours** tab → the week's line. 5. **Divine** → "career"
→ that entry ranks top. 6. **Owl Post** → the weekly reflection. 7. Unlock as a second account → **empty vault**
(prove isolation). 8. **The kicker:** `curl` the API with a valid ID token → `403 failed_app_check`.

## What we'd add next
Passkeys/MFA on sign-in, Firestore-backed distributed rate limiting, per-user CMEK, and native Firestore
vector search once the entry count outgrows in-process cosine ranking.
