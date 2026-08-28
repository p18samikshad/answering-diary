# The Answering Diary 🔒📓

**Personal Gemini Journal — Ideathon submission.** `#AccelerateAIwithCloudRun`

An authenticated web app where you write on a page and the page writes back. Every session is
summarized, read for its emotional register, embedded, and sealed into a vault only your hand can
open. Keys live in Secret Manager, never in code. Built with a Google AI Studio configured to
threat-model before it wrote a line.

> **The premise.** A diary that holds a multi-turn conversation, remembers everything you tell it,
> and answers in its own hand is a product spec — and very nearly Tom Riddle's. What made his
> catastrophic was not the feature set but four engineering decisions: no authentication, a vault
> shared with a hostile party, the secret key embedded in the artifact itself, and output that
> manipulated its user. This app fixes all four, and the pitch says so out loud.

## Stack
Vanilla HTML/CSS/JS · **Cloud Run** (Node 22 + Express, containerized) · Firebase Auth (Google) +
App Check · Cloud Firestore · Google Cloud Secret Manager · Gemini (an ordered fallback chain —
`gemini-2.5-flash-lite` → `gemini-2.5-flash` → `gemini-3.6-flash` — plus `gemini-embedding-001`) ·
Cloud Scheduler.

One Cloud Run service serves both the diary and its API, so the deployed `*.run.app` URL is the
entire application — and the browser never makes a cross-origin call.

## Repo layout
```
deploy.sh / deploy.ps1      One-command, idempotent deploy (bash and PowerShell)
verify.sh / verify.ps1      17 checks against the live service (gates, headers, no leaked key)
Dockerfile                  Cloud Run container — non-root, prod-only deps, no secrets baked in
package.json                The service (Express + Firebase Admin + Gemini + Secret Manager)
server.js                   Static frontend + authed /api + OIDC-gated /jobs/owlpost
lib/appcheck.js             App Check verification — monitor / enforce / off
lib/secrets.js              Secret Manager access (Gemini key, fetched at runtime)
lib/gemini.js               inscribe · readTheInk · embed · owlPost · whisper
lib/journal.js              sealMemory · recallMemories · divineMemories · humourSeries · computeVigil
public/                     The diary
  index.html  styles.css  app.js  config.js   (config.js = public Firebase config, fill in)
firestore.rules             Default-deny, per-writer isolation
firebase.json               Firestore rules + emulators (the app itself runs on Cloud Run)
.firebaserc                 Project id (fill in)
.env.example                Non-secret runtime config
AI_STUDIO_CONSTITUTION.md   Phase 1 — security system-instructions for Google AI Studio
SUBMISSION.md               Judge-facing writeup: requirements, architecture, STRIDE
DEPLOY.md                   Copy-paste runbook (create project → deployed Cloud Run URL)
pitch.html                  The one-page pitch (published as an Artifact)
```

## The vocabulary
The app is an enchanted diary, so the data contract speaks its language. This is cosmetic — the
security model is unchanged.

| Concept | In the code |
|---|---|
| A saved session | a **memory** — `users/{uid}/memories` |
| Its emotional register | **humour** + `humourScore` (1–10) |
| Its tags / next steps | **threads** / **resolutions** |
| Weekly reflection | **Owl Post** — `users/{uid}/owlpost` |
| Consecutive nights written | the **vigil** |
| API actions | `inscribe · seal · recall · divine · humours · whisper · owlpost` |

## Core requirements ✅
- **Auth** — Firebase Google sign-in; ID token verified server-side, uid from the token. Plus
  **App Check** so a stolen token can't be replayed from a non-app client.
- **Multi-turn Gemini** — rolling history, server-side calls, fixed journaling system instruction.
- **Isolated storage** — `users/{uid}/memories` + default-deny rules; zero cross-writer leakage.
- **Secret management** — Gemini key in Secret Manager, fetched at runtime, least-privilege IAM.

## Enhancements ✨
The Humours (mood dashboard) · Divination (semantic memory search) · Owl Post (scheduled weekly
reflection) · the Vigil & the Whisper (streaks + personalized prompts).

## Quick start

Fastest path is **[Google Cloud Shell](https://shell.cloud.google.com)** — `gcloud` and `firebase`
are preinstalled and already authenticated as you.

```bash
gcloud auth login && firebase login    # not needed in Cloud Shell
./deploy.sh                            # macOS / Linux / Cloud Shell / Git Bash / WSL
.\deploy.ps1                           # Windows PowerShell
```

One script runs the whole deploy: project, APIs, Firestore, Secret Manager, a least-privilege
service account, security rules, the Cloud Run service, the authorised sign-in domain, and the
weekly schedule. It is safe to re-run, and it prints your `*.run.app` URL at the end — that is the
working prototype link you submit.

```bash
./deploy.sh --dry-run     # show what it would do, change nothing
./deploy.sh --enforce     # switch App Check to enforce mode
./deploy.sh --redeploy    # code changed only: rebuild and ship
./verify.sh <url>         # 17 checks against the live service
```

Full step-by-step, and what to do if a step fails, in **DEPLOY.md**.

## Security at a glance
No secrets in source (`grep` it). Default-deny database. Token-derived identity. App Check
attestation. Rate limits and body caps. The diary's replies are rendered with `textContent`, never
`innerHTML` — nothing written on the page can execute. Full STRIDE table in `SUBMISSION.md`.

## A note on the diary's voice
The system instruction is server-side and fixed: warm and curious, honest rather than flattering,
and explicitly encouraging of the writer's real-world relationships. The aesthetic borrows from the
famous enchanted diary; the behaviour deliberately does not.
