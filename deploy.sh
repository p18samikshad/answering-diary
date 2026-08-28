#!/usr/bin/env bash
# =============================================================================
#  The Answering Diary — one-command deploy to Cloud Run.
#
#  Runs every step of DEPLOY.md. Safe to re-run: every step checks whether the
#  thing already exists before creating it, so if the script dies halfway you
#  just run it again.
#
#  Usage:
#     ./deploy.sh                 # full deploy (prompts for what it needs)
#     ./deploy.sh --dry-run       # print what it would do, change nothing
#     ./deploy.sh --enforce       # deploy and turn App Check to enforce mode
#     ./deploy.sh --redeploy      # skip setup, just rebuild and ship the code
# =============================================================================
set -euo pipefail

# ---------- appearance ----------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi

STEP=0
step()  { STEP=$((STEP+1)); printf "\n%s──[ %02d ] %s%s\n" "$BOLD$CYN" "$STEP" "$1" "$RST"; }
ok()    { printf "  %s✓%s %s\n" "$GRN" "$RST" "$1"; }
skip()  { printf "  %s•%s %s %s(already done)%s\n" "$DIM" "$RST" "$1" "$DIM" "$RST"; }
warn()  { printf "  %s!%s %s\n" "$YLW" "$RST" "$1"; }
die()   { printf "\n%s✗ %s%s\n\n" "$RED$BOLD" "$1" "$RST" >&2; exit 1; }
act()   { printf "  %s→%s %s\n" "$CYN" "$RST" "$1"; }

DRY_RUN=0; ENFORCE=0; REDEPLOY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --enforce)  ENFORCE=1 ;;
    --redeploy) REDEPLOY_ONLY=1 ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown flag: $arg  (try --help)" ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then printf "  %s[dry-run]%s %s\n" "$DIM" "$RST" "$*"; return 0; fi
  "$@"
}

# =============================================================================
step "Preflight"
# =============================================================================
cd "$(dirname "$0")"

for f in Dockerfile package.json server.js public/index.html firestore.rules; do
  [ -f "$f" ] || die "Missing $f — run this from the repo root."
done
ok "Repo files present"

command -v gcloud   >/dev/null || die "gcloud not found. Install: https://cloud.google.com/sdk/docs/install"
command -v firebase >/dev/null || die "firebase not found. Install: npm i -g firebase-tools"
ok "gcloud $(gcloud version 2>/dev/null | head -1 | awk '{print $NF}') · firebase $(firebase --version 2>/dev/null)"

gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
  || die "Not logged in to gcloud. Run: gcloud auth login"
ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)
ok "gcloud account: $ACTIVE_ACCT"

# Check AUTH ONLY. `login:list` reads local credentials and touches no Google API, so it
# cannot fail for unrelated reasons — unlike `projects:list`, which needs the Firebase
# Management API enabled and would report an API problem as a login problem.
# Run from /tmp: the CLI validates .firebaserc in the cwd before doing anything.
FB_ACCTS=$( (cd /tmp && firebase login:list) 2>&1 || true )
if grep -qiE "no authorized accounts|not logged in|no users" <<< "$FB_ACCTS"; then
  die "Not logged in to firebase. Run:  cd ~ && firebase login --no-localhost"
fi
ok "firebase authenticated"

# ---------- settings ----------
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-asia-south1}"
SERVICE="${SERVICE:-answering-diary}"

if [ -z "$PROJECT_ID" ]; then
  DEFAULT_PID="answering-diary-$(date +%s | tail -c 5)"
  read -rp "  Project id [$DEFAULT_PID]: " PROJECT_ID
  PROJECT_ID="${PROJECT_ID:-$DEFAULT_PID}"
fi
read -rp "  Region [$REGION]: " _r; REGION="${_r:-$REGION}"

printf "\n  %sProject%s  %s\n  %sRegion %s  %s\n  %sService%s  %s\n" \
  "$DIM" "$RST" "$PROJECT_ID" "$DIM" "$RST" "$REGION" "$DIM" "$RST" "$SERVICE"
read -rp "
  Proceed? [Y/n] " _c; case "${_c:-Y}" in [nN]*) die "Cancelled." ;; esac

RUNTIME_SA="diary-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
SCHED_SA="diary-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"

if [ "$REDEPLOY_ONLY" = "1" ]; then
  step "Redeploy only — rebuilding and shipping"
  run gcloud run deploy "$SERVICE" --source . --region "$REGION" --project "$PROJECT_ID" --quiet
  URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')
  ok "Live at $URL"
  exit 0
fi

# =============================================================================
step "Project and billing"
# =============================================================================
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  skip "Project $PROJECT_ID exists"
else
  act "Creating project $PROJECT_ID"
  run gcloud projects create "$PROJECT_ID" --name="The Answering Diary"
  ok "Project created"
fi
run gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

BILLING_OK=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo "False")
if [ "$BILLING_OK" = "True" ]; then
  skip "Billing already linked"
else
  warn "Billing is not linked. Cloud Run and Secret Manager require it."
  echo ""
  gcloud billing accounts list 2>/dev/null || warn "Could not list billing accounts."
  echo ""
  read -rp "  Billing account id (XXXXXX-XXXXXX-XXXXXX), or blank to link manually later: " BILLING_ID
  if [ -n "$BILLING_ID" ]; then
    run gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID"
    ok "Billing linked"
  else
    die "Billing is required. Link it in the console, then re-run this script."
  fi
fi

# =============================================================================
step "Enabling APIs (this takes a minute)"
# =============================================================================
run gcloud services enable \
  firebase.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  firestore.googleapis.com \
  identitytoolkit.googleapis.com \
  firebaseappcheck.googleapis.com \
  recaptchaenterprise.googleapis.com \
  generativelanguage.googleapis.com \
  cloudscheduler.googleapis.com \
  --project "$PROJECT_ID"
ok "APIs enabled"

# =============================================================================
step "Firebase and Firestore"
# =============================================================================
# By now firebase.googleapis.com is enabled, so the Management API is reachable.
if (cd /tmp && firebase projects:list 2>/dev/null) | grep -q "$PROJECT_ID"; then
  skip "Firebase already added to project"
else
  act "Adding Firebase to the project"
  if ! run firebase projects:addfirebase "$PROJECT_ID"; then
    warn "Could not add Firebase automatically."
    echo "     Add it once in the console, then re-run this script:"
    echo "     https://console.firebase.google.com/  →  Add project  →  pick $PROJECT_ID"
    die "Firebase must be added to the project before continuing."
  fi
  ok "Firebase added"
fi

if gcloud firestore databases describe --project "$PROJECT_ID" >/dev/null 2>&1; then
  skip "Firestore database exists"
else
  act "Creating Firestore database"
  run gcloud firestore databases create --location="$REGION" --project "$PROJECT_ID" \
    || run gcloud firestore databases create --location=nam5 --project "$PROJECT_ID"
  ok "Firestore created"
fi

# =============================================================================
step "Web app and public config"
# =============================================================================
APP_ID=$(firebase apps:list WEB --project "$PROJECT_ID" 2>/dev/null | grep -oE '1:[0-9]+:web:[a-f0-9]+' | head -1 || true)
if [ -z "$APP_ID" ]; then
  act "Registering a Firebase web app"
  run firebase apps:create WEB "The Answering Diary" --project "$PROJECT_ID" >/dev/null
  APP_ID=$(firebase apps:list WEB --project "$PROJECT_ID" 2>/dev/null | grep -oE '1:[0-9]+:web:[a-f0-9]+' | head -1 || true)
  ok "Web app registered"
else
  skip "Web app exists"
fi

if [ "$DRY_RUN" = "0" ] && [ -n "$APP_ID" ]; then
  act "Writing public/config.js from the live project config"
  SDK_JSON=$(firebase apps:sdkconfig WEB "$APP_ID" --project "$PROJECT_ID" --json 2>/dev/null || echo "")
  if [ -n "$SDK_JSON" ]; then
    EXISTING_SITE_KEY=$(grep -oE 'appCheckSiteKey:[[:space:]]*"[^"]*"' public/config.js 2>/dev/null | sed 's/.*"\(.*\)"/\1/' || echo "")
    [ -z "$EXISTING_SITE_KEY" ] && EXISTING_SITE_KEY="YOUR_RECAPTCHA_V3_SITE_KEY"
    SITE_KEY="$EXISTING_SITE_KEY" node -e '
      const raw = JSON.parse(process.argv[1]);
      const c = raw.result ? raw.result.sdkConfig : (raw.sdkConfig || raw);
      const out = `// Public Firebase web config — safe to expose (identifiers, NOT secrets).
// Generated by deploy.sh from the live project. The Gemini key is NOT here:
// it lives in Secret Manager and is used only server-side.
window.APP_CONFIG = {
  firebase: {
    apiKey: ${JSON.stringify(c.apiKey)},
    authDomain: ${JSON.stringify(c.authDomain)},
    projectId: ${JSON.stringify(c.projectId)},
    appId: ${JSON.stringify(c.appId)},
  },
  // Same origin — this Cloud Run service serves both the diary and its API.
  apiBase: "/api",

  // App Check (reCAPTCHA v3). Public by design. Register the site key at
  // Firebase Console -> App Check -> Apps -> your web app -> reCAPTCHA v3.
  appCheckSiteKey: ${JSON.stringify(process.env.SITE_KEY)},
  appCheckDebug: false,
};
`;
      require("fs").writeFileSync("public/config.js", out);
    ' "$SDK_JSON"
    ok "public/config.js written for $PROJECT_ID"
    [ "$EXISTING_SITE_KEY" = "YOUR_RECAPTCHA_V3_SITE_KEY" ] \
      && warn "App Check site key still a placeholder — fine for now (monitor mode)."
  else
    warn "Could not fetch the SDK config. Fill public/config.js by hand."
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  printf "  %s[dry-run]%s would write .firebaserc\n" "$DIM" "$RST"
else
  echo "{\"projects\":{\"default\":\"$PROJECT_ID\"}}" > .firebaserc
  ok ".firebaserc set"
fi

# =============================================================================
step "Google sign-in — one manual step"
# =============================================================================
cat <<EOF
  This one cannot be scripted. In another tab:

    ${BOLD}https://console.firebase.google.com/project/$PROJECT_ID/authentication/providers${RST}

    Authentication -> Sign-in method -> Google -> Enable -> Save
EOF
read -rp "
  Press Enter once Google sign-in is enabled… " _

# =============================================================================
step "Gemini API key -> Secret Manager"
# =============================================================================
if gcloud secrets describe GEMINI_API_KEY --project "$PROJECT_ID" >/dev/null 2>&1; then
  skip "Secret GEMINI_API_KEY exists"
  read -rp "  Add a new version (rotate the key)? [y/N] " _rot
  case "${_rot:-N}" in
    [yY]*)
      read -rsp "  Paste the Gemini API key (hidden): " GEM_KEY; echo ""
      [ -n "$GEM_KEY" ] || die "Empty key."
      printf '%s' "$GEM_KEY" | run gcloud secrets versions add GEMINI_API_KEY --data-file=- --project "$PROJECT_ID"
      unset GEM_KEY
      ok "New secret version added"
      ;;
  esac
else
  echo "  Get one from Google AI Studio -> Get API key."
  read -rsp "  Paste the Gemini API key (hidden): " GEM_KEY; echo ""
  [ -n "$GEM_KEY" ] || die "Empty key."
  if [ "$DRY_RUN" = "1" ]; then
    printf "  %s[dry-run]%s would create secret GEMINI_API_KEY\n" "$DIM" "$RST"
  else
    printf '%s' "$GEM_KEY" | gcloud secrets create GEMINI_API_KEY \
      --data-file=- --replication-policy=automatic --project "$PROJECT_ID"
  fi
  unset GEM_KEY
  ok "Secret created (never written to disk, never echoed)"
fi

# =============================================================================
step "Least-privilege service accounts"
# =============================================================================
if gcloud iam service-accounts describe "$RUNTIME_SA" --project "$PROJECT_ID" >/dev/null 2>&1; then
  skip "Runtime service account exists"
else
  run gcloud iam service-accounts create diary-runtime \
    --display-name="Answering Diary runtime" --project "$PROJECT_ID"
  ok "Runtime service account created"
fi

act "Granting exactly three roles (not the broad default account)"
run gcloud secrets add-iam-policy-binding GEMINI_API_KEY \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/secretmanager.secretAccessor" \
  --project "$PROJECT_ID" >/dev/null
run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/datastore.user" >/dev/null
run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/firebaseauth.viewer" >/dev/null
ok "secretAccessor · datastore.user · firebaseauth.viewer"

# =============================================================================
step "Firestore security rules"
# =============================================================================
act "Deploying default-deny, per-writer isolation rules"
run firebase deploy --only firestore:rules --project "$PROJECT_ID"
ok "Rules live — the vault was never briefly open"

# =============================================================================
step "Deploying to Cloud Run (builds the container; a few minutes)"
# =============================================================================
run gcloud run deploy "$SERVICE" \
  --source . \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --service-account "$RUNTIME_SA" \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 10 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 60 \
  --set-env-vars "APPCHECK_MODE=monitor,GEMINI_CHAT_MODELS=gemini-2.5-flash-lite;gemini-2.5-flash;gemini-3.6-flash,GEMINI_EMBED_MODELS=gemini-embedding-001" \
  --quiet

if [ "$DRY_RUN" = "1" ]; then
  URL="https://${SERVICE}-dryrun.a.run.app"
else
  URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')
fi
[ -n "$URL" ] || die "Could not read the service URL."
ok "Deployed: $URL"

# =============================================================================
step "Authorising the domain for Google sign-in"
# =============================================================================
HOST="${URL#https://}"
if [ "$DRY_RUN" = "1" ]; then
  printf "  %s[dry-run]%s would authorise %s\n" "$DIM" "$RST" "$HOST"
else
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
  CUR=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config" 2>/dev/null || echo "")
  if echo "$CUR" | grep -q "$HOST"; then
    skip "$HOST already authorised"
  elif [ -n "$CUR" ] && echo "$CUR" | grep -q "authorizedDomains"; then
    BODY=$(HOSTV="$HOST" node -e '
      const cfg = JSON.parse(require("fs").readFileSync(0,"utf8"));
      const d = cfg.authorizedDomains || [];
      if (!d.includes(process.env.HOSTV)) d.push(process.env.HOSTV);
      process.stdout.write(JSON.stringify({ authorizedDomains: d }));
    ' <<< "$CUR")
    RESP=$(curl -s -X PATCH \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      "https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config?updateMask=authorizedDomains" \
      -d "$BODY" 2>/dev/null || echo "")
    if echo "$RESP" | grep -q "$HOST"; then
      ok "$HOST authorised for sign-in"
    else
      warn "Could not authorise automatically. Add it by hand:"
      echo "     Firebase Console -> Authentication -> Settings -> Authorised domains -> $HOST"
    fi
  else
    warn "Could not read the auth config. Add $HOST manually under Authorised domains."
  fi
fi

# =============================================================================
step "Weekly Owl Post schedule"
# =============================================================================
if gcloud iam service-accounts describe "$SCHED_SA" --project "$PROJECT_ID" >/dev/null 2>&1; then
  skip "Scheduler service account exists"
else
  run gcloud iam service-accounts create diary-scheduler \
    --display-name="Answering Diary scheduler" --project "$PROJECT_ID"
  ok "Scheduler service account created"
fi

run gcloud run services add-iam-policy-binding "$SERVICE" --region "$REGION" --project "$PROJECT_ID" \
  --member="serviceAccount:${SCHED_SA}" --role="roles/run.invoker" >/dev/null
ok "Scheduler may invoke the service"

act "Telling the service which caller to trust"
run gcloud run services update "$SERVICE" --region "$REGION" --project "$PROJECT_ID" \
  --update-env-vars "SCHEDULER_SA=${SCHED_SA},JOB_AUDIENCE=${URL}/jobs/owlpost" --quiet >/dev/null

if gcloud scheduler jobs describe owlpost-weekly --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  run gcloud scheduler jobs update http owlpost-weekly --location "$REGION" --project "$PROJECT_ID" \
    --schedule "0 8 * * 1" --time-zone "Asia/Kolkata" \
    --uri "${URL}/jobs/owlpost" --http-method POST \
    --oidc-service-account-email "$SCHED_SA" --oidc-token-audience "${URL}/jobs/owlpost" >/dev/null
  ok "Weekly schedule updated"
else
  run gcloud scheduler jobs create http owlpost-weekly --location "$REGION" --project "$PROJECT_ID" \
    --schedule "0 8 * * 1" --time-zone "Asia/Kolkata" \
    --uri "${URL}/jobs/owlpost" --http-method POST \
    --oidc-service-account-email "$SCHED_SA" --oidc-token-audience "${URL}/jobs/owlpost" >/dev/null
  ok "Weekly schedule created — Mondays 08:00 IST"
fi

# =============================================================================
step "Optional: App Check enforce mode"
# =============================================================================
if [ "$ENFORCE" = "1" ]; then
  run gcloud run services update "$SERVICE" --region "$REGION" --project "$PROJECT_ID" \
    --update-env-vars "APPCHECK_MODE=enforce" --quiet >/dev/null
  ok "Enforce mode ON — unattested clients are refused"
else
  skip "Left in monitor mode (recommended first deploy)"
  echo "     Register reCAPTCHA v3 at App Check, put the site key in public/config.js,"
  echo "     watch the metrics, then re-run:  ./deploy.sh --enforce"
fi

# =============================================================================
step "Verifying"
# =============================================================================
if [ "$DRY_RUN" = "1" ]; then
  warn "Dry run — nothing was deployed, so nothing to verify."
else
  ./verify.sh "$URL" || warn "Some checks failed — see above."
fi

# =============================================================================
printf "\n%s%s  The diary is open.%s\n\n" "$BOLD" "$GRN" "$RST"
printf "  %sPrototype link (submit this):%s\n  %s%s%s\n\n" "$DIM" "$RST" "$BOLD" "$URL" "$RST"
cat <<EOF
  Next:
    1. Open it, sign in, write a page, seal a memory.
    2. Open incognito as a second Google account — the vault should be empty.
    3. Register App Check, then:  ./deploy.sh --enforce
    4. Logs:  gcloud run services logs read $SERVICE --region $REGION --limit 50

EOF
