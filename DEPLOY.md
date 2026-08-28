# Deploy Runbook — The Answering Diary (Cloud Run)

*Personal Gemini Journal · #AccelerateAIwithCloudRun*

## Where to run this

| You are on | Run |
|---|---|
| **Anything — the fastest path** | **[Google Cloud Shell](https://shell.cloud.google.com)** — a browser terminal with `gcloud`, `firebase`, `git` and Node already installed and *already authenticated*. Nothing to install, and no Windows/bash mismatch. |
| macOS or Linux | Terminal — `./deploy.sh` |
| Windows, PowerShell | `.\deploy.ps1` (a full port, same behaviour) |
| Windows, Git Bash or WSL | `./deploy.sh` |

**PowerShell cannot run `deploy.sh`** — it is a bash script. Use `deploy.ps1` there, or use Cloud Shell.

### Cloud Shell in three commands

```bash
# In https://shell.cloud.google.com, after uploading or cloning the repo:
cd answering-diary
chmod +x deploy.sh verify.sh
./deploy.sh
```

Upload the zip with the Cloud Shell **⋮ → Upload** menu, then `unzip the-answering-diary.zip`.
Cloud Shell is already signed in as your Google account, so you can skip `gcloud auth login`
entirely. If `firebase` is missing, `npm i -g firebase-tools` takes about thirty seconds.

---

## The short way

Everything below is automated. From the repo root:

```bash
./deploy.sh          # macOS, Linux, Cloud Shell, Git Bash, WSL
.\deploy.ps1         # Windows PowerShell
```

It runs every step on this page, is **safe to re-run** (each step checks whether the thing already
exists), never writes your Gemini key to disk, generates `public/config.js` from the live project,
and finishes by verifying the deployed service. Two things it will pause and ask you to do in the
console — enabling Google sign-in, and registering App Check — because neither is scriptable.

```bash
./deploy.sh --dry-run     # show what it would do, change nothing
./deploy.sh --enforce     # deploy and switch App Check to enforce mode
./deploy.sh --redeploy    # code changed only: rebuild and ship
./verify.sh <url>         # re-run the checks any time
```

PowerShell uses the same flags with a single dash: `.\deploy.ps1 -DryRun`, `-Enforce`, `-Redeploy`,
and `.\verify.ps1 <url>`. If PowerShell blocks the script, that is the execution policy, not the
script — allow it for this window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**Prerequisites:** `gcloud auth login` and `firebase login` done, and a billing account available.
(In Cloud Shell, the gcloud login is already done for you.)

---

## The long way — what the script actually does

Read this if you would rather run the steps yourself, or if `deploy.sh` stops somewhere and you
want to continue by hand. Budget **45–60 minutes** the first time.

The deployed **Cloud Run URL is your submission's prototype link** — one service serves both the
diary and its API, so there is exactly one URL to hand the judges.

---

## 0. Prerequisites

```bash
npm i -g firebase-tools
# gcloud: https://cloud.google.com/sdk/docs/install

export PROJECT_ID="answering-diary-$(whoami)"   # must be globally unique
export REGION="asia-south1"                      # Mumbai; use us-central1 if you prefer
export SERVICE="answering-diary"

gcloud auth login
firebase login
```

## 1. Create the project and enable APIs

```bash
gcloud projects create "$PROJECT_ID" --name="The Answering Diary"
gcloud config set project "$PROJECT_ID"

# Billing is required for Cloud Run + Secret Manager. Find your account id, then link it:
gcloud billing accounts list
gcloud billing projects link "$PROJECT_ID" --billing-account=XXXXXX-XXXXXX-XXXXXX

gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  firestore.googleapis.com \
  identitytoolkit.googleapis.com \
  firebaseappcheck.googleapis.com \
  generativelanguage.googleapis.com \
  cloudscheduler.googleapis.com
```

## 2. Firestore and Firebase Auth

```bash
firebase projects:addfirebase "$PROJECT_ID"
gcloud firestore databases create --location=nam5   # or asia-south1 to match your region
```

Then two console clicks:

1. **Firebase Console → Authentication → Sign-in method → Google → Enable.**
2. **Firebase Console → Project settings → Your apps → Web (`</>`) → Register**, and copy the
   config object — you need it in step 5.

## 3. Put the Gemini key in Secret Manager (never in code)

```bash
# Get a key from Google AI Studio → Get API key.
printf '%s' "YOUR_GEMINI_API_KEY" | \
  gcloud secrets create GEMINI_API_KEY --data-file=- --replication-policy=automatic
```

## 4. Create a least-privilege runtime service account

The default Compute service account is far too broad. Give the diary its own identity with exactly
three permissions: read the secret, use Firestore, verify tokens.

```bash
gcloud iam service-accounts create diary-runtime \
  --display-name="Answering Diary runtime"

export RUNTIME_SA="diary-runtime@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud secrets add-iam-policy-binding GEMINI_API_KEY \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/datastore.user"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/firebaseauth.viewer"
```

> **Say this to the judges.** A dedicated runtime service account with three roles is the difference
> between "it works" and "it is built responsibly" — one of the four judging criteria.

## 5. Enable App Check and fill in the config

```bash
# App Check proves requests come from YOUR app, not a script replaying a stolen token.
```

1. **Firebase Console → App Check → Apps →** your Web app → **reCAPTCHA v3** → Register.
2. Copy the **site key**.
3. Edit `public/config.js`: paste the Firebase web config and the App Check site key.
   These are public identifiers, not secrets — the Gemini key is nowhere near the browser.
4. Edit `.firebaserc`: replace `YOUR_FIREBASE_PROJECT_ID` with your project id.

## 6. Deploy the Firestore security rules

Do this **before** first use, so the vault is never briefly open.

```bash
firebase use "$PROJECT_ID"
firebase deploy --only firestore:rules
```

## 7. Deploy to Cloud Run

```bash
gcloud run deploy "$SERVICE" \
  --source . \
  --region "$REGION" \
  --service-account "$RUNTIME_SA" \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 10 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 60 \
  --set-env-vars "APPCHECK_MODE=monitor,GEMINI_CHAT_MODELS=gemini-2.5-flash-lite;gemini-2.5-flash;gemini-3.6-flash,GEMINI_EMBED_MODELS=gemini-embedding-001"
```

`--allow-unauthenticated` lets browsers reach the sign-in page; **every** `/api` route still requires
a verified Firebase ID token. Public route, private data.

`GEMINI_CHAT_MODELS` is an **ordered fallback chain**, not a single model. The diary tries each in turn
and moves on when one answers `RESOURCE_EXHAUSTED` / `429` / "no longer available" — so a depleted daily
quota or a retired model degrades the service instead of breaking it. Note the **semicolons**: `gcloud`
reads a comma as the separator *between* environment variables, so the chain uses `;` inside its value.
Confirm what the running service will actually use:

```bash
curl -s "$URL/healthz"
# {"status":"ok","models":{"chat":["gemini-2.5-flash-lite","gemini-2.5-flash","gemini-3.6-flash"],...}}
```

If you are updating an already-deployed service rather than redeploying, add the chain and clear the
older singular variables in one call (a leftover `GEMINI_CHAT_MODEL` is ignored by the parser, but
removing it keeps the config honest):

```bash
gcloud run services update "$SERVICE" --region "$REGION" \
  --update-env-vars "GEMINI_CHAT_MODELS=gemini-2.5-flash-lite;gemini-2.5-flash;gemini-3.6-flash,GEMINI_EMBED_MODELS=gemini-embedding-001" \
  --remove-env-vars GEMINI_CHAT_MODEL,GEMINI_EMBED_MODEL
```

Capture your URL — this is the prototype link you submit:

```bash
export SERVICE_URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')
echo "$SERVICE_URL"
```

Add it to Firebase's authorised domains, or Google sign-in will fail:
**Firebase Console → Authentication → Settings → Authorised domains → Add domain** → the
`*.run.app` hostname (no `https://`).

## 8. Schedule the weekly Owl Post

Cloud Scheduler calls the job endpoint with a signed OIDC token, which the server verifies against
this exact service account before doing anything.

```bash
gcloud iam service-accounts create diary-scheduler --display-name="Answering Diary scheduler"
export SCHED_SA="diary-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud run services add-iam-policy-binding "$SERVICE" --region "$REGION" \
  --member="serviceAccount:${SCHED_SA}" --role="roles/run.invoker"

# Tell the service which caller and audience to trust.
gcloud run services update "$SERVICE" --region "$REGION" \
  --update-env-vars "SCHEDULER_SA=${SCHED_SA},JOB_AUDIENCE=${SERVICE_URL}/jobs/owlpost"

gcloud scheduler jobs create http owlpost-weekly \
  --location "$REGION" \
  --schedule "0 8 * * 1" \
  --time-zone "Asia/Kolkata" \
  --uri "${SERVICE_URL}/jobs/owlpost" \
  --http-method POST \
  --oidc-service-account-email "$SCHED_SA" \
  --oidc-token-audience "${SERVICE_URL}/jobs/owlpost"
```

## 9. Verify — this is your demo script

```bash
open "$SERVICE_URL"   # macOS; use xdg-open or just paste into a browser
```

- Unlock the diary with Google → write a page → the reply's ink rises.
- **Seal this memory** → a card appears with its humour and threads; the vigil ticks.
- **Humours / Divine / Owl Post** tabs all return.
- **Isolation, demonstrated:** unlock in an incognito window as a second Google account → an empty
  vault. Zero memories cross over.

Then prove the gates from a terminal:

```bash
curl -s -o /dev/null -w "no token      -> %{http_code}\n" \
  -X POST "$SERVICE_URL/api" -H 'Content-Type: application/json' -d '{"action":"recall"}'
# expect 401

curl -s -o /dev/null -w "scheduler job -> %{http_code}\n" -X POST "$SERVICE_URL/jobs/owlpost"
# expect 403
```

## 10. Harden before you submit

Watch **Firebase Console → App Check → Metrics** until your own traffic shows as verified
(usually minutes). Then close the door:

```bash
gcloud run services update "$SERVICE" --region "$REGION" \
  --update-env-vars "APPCHECK_MODE=enforce"
```

Now the closing demo works — a *valid* ID token, replayed without attestation, is refused:

```bash
curl -s -X POST "$SERVICE_URL/api" \
  -H "Authorization: Bearer <a real ID token from your browser devtools>" \
  -H 'Content-Type: application/json' -d '{"action":"recall"}'
# {"error":"failed_app_check"}
```

> Record this. It is the single most persuasive ten seconds in the demo.

---

## Local development

```bash
npm install
cp .env.example .env          # set GOOGLE_CLOUD_PROJECT, APPCHECK_MODE=off
gcloud auth application-default login
npm start                     # http://localhost:8080
```

For App Check locally: set `appCheckDebug: true` in `public/config.js`, open the app, copy the debug
token the console prints, and register it under **App Check → Apps → Manage debug tokens**.

## Rotating the Gemini key

```bash
printf '%s' "NEW_KEY" | gcloud secrets versions add GEMINI_API_KEY --data-file=-
```

No redeploy needed — the service reads `versions/latest` and refreshes its cache within ten minutes.

## Cost guardrails already in place

| Guardrail | Value |
|---|---|
| Scale to zero | `--min-instances 0` — you pay nothing while idle |
| Instance ceiling | `--max-instances 10` |
| Request timeout | 60s |
| Per-user rate limit | 30 requests/minute |
| Request body cap | 60 KB |
| Secret cache | 10 minutes, cutting Secret Manager calls |

## If something breaks

```bash
gcloud run services logs read "$SERVICE" --region "$REGION" --limit 50
```

| Symptom | Cause | Fix |
|---|---|---|
| Sign-in popup closes instantly | Cloud Run domain not authorised | Add the `run.app` host in Firebase Auth → Settings → Authorised domains |
| `500 internal_error` on every action | Runtime SA can't read the secret | Re-run the `secretAccessor` binding in step 4 |
| `403 failed_app_check` in your own browser | Enforce mode on, site key missing or wrong | Check `appCheckSiteKey` in `public/config.js`, or set `APPCHECK_MODE=monitor` |
| `PERMISSION_DENIED` writing a memory | Rules not deployed | `firebase deploy --only firestore:rules` |
| Build fails on deploy | Cloud Build API not enabled | Re-run the `gcloud services enable` block in step 1 |
