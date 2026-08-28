#!/usr/bin/env bash
# =============================================================================
#  App Check, demonstrated rather than asserted.
#
#  Auth proves WHO is writing. App Check proves WHAT is writing. The claim worth
#  showing is that the second one is load-bearing: take a request the real app
#  made, keep the valid Firebase ID token, remove only the attestation header,
#  and watch the same request stop working.
#
#  Usage
#    1. In the app, open DevTools -> Network, click any tab to fire a request.
#    2. Right-click the `api` request -> Copy -> "Copy as cURL (bash)".
#    3. Paste into a file:   cat > req.txt      (paste, then Ctrl-D)
#    4. ./appcheck-demo.sh req.txt
#
#  Nothing from the file is ever printed, so the ID token stays off screen and
#  out of your scrollback. Safe to run while recording.
# =============================================================================
set -uo pipefail

SRC="${1:-req.txt}"
[ -f "$SRC" ] || { echo "No such file: $SRC"; echo "See the usage notes at the top of this script."; exit 1; }
grep -qi 'x-firebase-appcheck' "$SRC" || {
  echo "That request carries no x-firebase-appcheck header, so there is nothing to remove."
  echo "Copy a request made by the app itself while App Check is initialised."
  exit 1
}

if [ -t 1 ]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; RED=$'\033[31m'; RST=$'\033[0m'
else BOLD=""; DIM=""; GRN=""; RED=""; RST=""; fi

WORK=$(mktemp -d); chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

python3 - "$SRC" "$WORK" <<'PY'
import sys, re
src, work = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8").read()

def finish(lines):
    # A copied cURL is one logical line split with trailing backslashes. Dropping a
    # header can leave a dangling continuation on the final line, so strip it.
    while lines and not lines[-1].strip():
        lines.pop()
    if lines:
        lines[-1] = re.sub(r'\\\s*$', '', lines[-1])
    return "\n".join(lines) + " -s -w '\\n%{http_code}\\n'\n"

lines = raw.splitlines()
open(work + "/with.sh", "w", encoding="utf-8").write(finish(list(lines)))
stripped = [l for l in lines if 'x-firebase-appcheck' not in l.lower()]
open(work + "/without.sh", "w", encoding="utf-8").write(finish(stripped))
PY
chmod 600 "$WORK"/*.sh

run() { bash "$1" 2>/dev/null; }

echo
printf "%sSame user. Same token. One header apart.%s\n\n" "$BOLD" "$RST"

OUT_WITH=$(run "$WORK/with.sh");       CODE_WITH=$(tail -n1 <<< "$OUT_WITH")
OUT_WITHOUT=$(run "$WORK/without.sh"); CODE_WITHOUT=$(tail -n1 <<< "$OUT_WITHOUT")
BODY_WITHOUT=$(sed '$d' <<< "$OUT_WITHOUT" | tail -c 120)

printf "  with app attestation      %s%s%s\n" \
  "$([ "$CODE_WITH" = "200" ] && echo "$GRN" || echo "$RED")" "$CODE_WITH" "$RST"
printf "  without app attestation   %s%s%s   %s%s%s\n" \
  "$([ "$CODE_WITHOUT" = "403" ] && echo "$GRN" || echo "$RED")" "$CODE_WITHOUT" "$RST" \
  "$DIM" "$BODY_WITHOUT" "$RST"
echo

if [ "$CODE_WITH" = "200" ] && [ "$CODE_WITHOUT" = "403" ]; then
  printf "  %sA valid token replayed from outside the app is refused.%s\n\n" "$GRN" "$RST"
  exit 0
fi

if [ "$CODE_WITH" = "401" ]; then
  echo "  The ID token has expired (they last an hour). Re-copy the request and try again."
elif [ "$CODE_WITHOUT" = "200" ]; then
  echo "  App Check is not enforcing. Switch APPCHECK_MODE to enforce and redeploy:"
  echo "    gcloud run services update \$SERVICE --region \$REGION --update-env-vars APPCHECK_MODE=enforce"
fi
exit 1
