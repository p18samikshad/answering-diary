#!/usr/bin/env bash
# =============================================================================
#  Post-deploy checks for The Answering Diary.
#
#  Proves the deployed service is up AND that its security gates actually
#  refuse what they should. Run it before you submit, and again on the day.
#
#  Usage:  ./verify.sh https://your-service-xxxx.a.run.app
#          ./verify.sh                 (reads the URL from gcloud)
# =============================================================================
set -uo pipefail

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; RST=""
fi

URL="${1:-}"
if [ -z "$URL" ]; then
  URL=$(gcloud run services describe "${SERVICE:-answering-diary}" \
        --region "${REGION:-asia-south1}" --format='value(status.url)' 2>/dev/null || echo "")
fi
[ -n "$URL" ] || { printf "%sNo URL. Pass one: ./verify.sh https://...run.app%s\n" "$RED" "$RST"; exit 1; }
URL="${URL%/}"

PASS=0; FAIL=0; WARN=0
# `expected` may list several acceptable codes, separated by |. The gates run in order --
# App Check, then auth -- so a request with no credentials is refused at whichever gate it
# reaches first: auth (401) in monitor mode, App Check (403) in enforce mode. Both are the
# gate working; accepting only one would report a failure every time enforce is switched on.
check() { # label  expected(a|b)  actual
  case "|$2|" in
    *"|$3|"*) printf "  %s\u2713%s %-42s %s\n" "$GRN" "$RST" "$1" "$3"; PASS=$((PASS+1)) ;;
    *)        printf "  %s\u2717%s %-42s got %s, expected %s\n" "$RED" "$RST" "$1" "$3" "$2"; FAIL=$((FAIL+1)) ;;
  esac
}
note() { printf "  %s!%s %s\n" "$YLW" "$RST" "$1"; WARN=$((WARN+1)); }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$@"; }

printf "\n%sVerifying%s %s\n\n" "$BOLD" "$RST" "$URL"

printf "%sReachable%s\n" "$BOLD" "$RST"
check "the diary loads"                 200 "$(code "$URL/")"
check "stylesheet"                      200 "$(code "$URL/styles.css")"
check "app script"                      200 "$(code "$URL/app.js")"
check "health probe"                    200 "$(code "$URL/status")"

# A single model is a single point of failure — quotas exhaust and models get retired.
# The service must be walking a chain, not betting on one name.
CHAIN=$(curl -s --max-time 25 "$URL/status" || echo "")
NMODELS=$(grep -oE '"gemini-[a-z0-9.-]+"' <<< "$CHAIN" | wc -l | tr -d ' ')
if [ "${NMODELS:-0}" -ge 3 ]; then
  printf "  %s\u2713%s %-42s %s models in the chain\n" "$GRN" "$RST" "model fallback chain live" "$NMODELS"; PASS=$((PASS+1))
else
  printf "  %s\u2717%s %-42s got %s, expected >=3 (chat chain + embed)\n" "$RED" "$RST" "model fallback chain live" "${NMODELS:-0}"; FAIL=$((FAIL+1))
fi

printf "\n%sThe gates refuse what they should%s\n" "$BOLD" "$RST"
JSON='{"action":"recall"}'
check "no token rejected"               "401|403" "$(code -X POST "$URL/api" -H 'Content-Type: application/json' -d "$JSON")"
# Browsers send Origin on every POST, same-origin included. The app's own page must get
# through CORS to the auth check (401), not be refused as a foreign origin (403).
check "own page passes CORS"            "401|403" "$(code -X POST "$URL/api" -H "Origin: $URL" -H 'Content-Type: application/json' -d "$JSON")"
check "forged token rejected"           "401|403" "$(code -X POST "$URL/api" -H 'Content-Type: application/json' -H 'Authorization: Bearer forged.token.value' -d "$JSON")"
check "foreign origin rejected"         403 "$(code -X POST "$URL/api" -H 'Origin: https://evil.example' -H 'Content-Type: application/json' -d "$JSON")"
check "scheduler job needs OIDC"        403 "$(code -X POST "$URL/jobs/owlpost")"
check "unknown action rejected"         "401|403" "$(code -X POST "$URL/api" -H 'Content-Type: application/json' -d '{"action":"drop_everything"}')"

BIG=$(head -c 70000 /dev/zero | tr '\0' 'x')
check "oversized body rejected"         413 "$(code -X POST "$URL/api" -H 'Content-Type: application/json' -d "{\"action\":\"inscribe\",\"message\":\"$BIG\"}")"
check "malformed json rejected"         400 "$(code -X POST "$URL/api" -H 'Content-Type: application/json' -d '{oops')"

printf "\n%sHardening%s\n" "$BOLD" "$RST"
HDRS=$(curl -s -D - -o /dev/null --max-time 25 "$URL/" 2>/dev/null)
for h in "X-Content-Type-Options" "X-Frame-Options" "Referrer-Policy"; do
  if grep -qi "^$h:" <<< "$HDRS"; then
    printf "  %s✓%s %-42s present\n" "$GRN" "$RST" "$h"; PASS=$((PASS+1))
  else
    printf "  %s✗%s %-42s missing\n" "$RED" "$RST" "$h"; FAIL=$((FAIL+1))
  fi
done
grep -qi "^x-powered-by:" <<< "$HDRS" && note "x-powered-by is exposed" \
  || { printf "  %s✓%s %-42s hidden\n" "$GRN" "$RST" "server fingerprint"; PASS=$((PASS+1)); }

printf "\n%sNo secret is being served to the browser%s\n" "$BOLD" "$RST"
CFG=$(curl -s --max-time 25 "$URL/config.js" 2>/dev/null || echo "")
if grep -qE 'appCheckSiteKey:[[:space:]]*"YOUR_' <<< "$CFG"; then
  note "App Check site key is still a placeholder (fine in monitor mode)"
fi
# Strip whole-line comments first — the file legitimately *mentions* the Gemini key
# in prose to say it is NOT here, and matching that would be a false alarm.
CFG_CODE=$(sed -e 's:^[[:space:]]*//.*::' <<< "$CFG")
# config.js may carry exactly one Google-style key: the public Firebase web apiKey.
NKEYS=$(grep -oE 'AIza[0-9A-Za-z_-]{30,}' <<< "$CFG_CODE" | wc -l | tr -d ' ')
GEMASSIGN=$(grep -ciE '(gemini|generativelanguage)[A-Za-z]*[[:space:]]*:[[:space:]]*"' <<< "$CFG_CODE" || true)
if [ "$NKEYS" -gt 1 ] || [ "$GEMASSIGN" -gt 0 ]; then
  printf "  %s✗%s %-42s %sA SECOND API KEY IS EXPOSED%s\n" "$RED" "$RST" "config.js" "$RED$BOLD" "$RST"; FAIL=$((FAIL+1))
else
  printf "  %s✓%s %-42s only public identifiers\n" "$GRN" "$RST" "config.js"; PASS=$((PASS+1))
fi

printf "\n%s%d passed%s" "$GRN" "$PASS" "$RST"
[ "$WARN" -gt 0 ] && printf ", %s%d warning(s)%s" "$YLW" "$WARN" "$RST"
[ "$FAIL" -gt 0 ] && printf ", %s%d failed%s" "$RED" "$FAIL" "$RST"
printf "\n\n"

if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
  ${DIM}Still to check by hand — a script cannot:${RST}
    · Sign in with Google and write a page.
    · Second Google account in incognito sees an EMPTY vault.
    · Open the URL on your phone, on mobile data, signed out.

EOF
  exit 0
fi
exit 1
