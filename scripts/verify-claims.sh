#!/usr/bin/env bash
# Verify every checkable claim in this repo against reality.
#
# Written 2026-08-02 after a review night where three separate passes each
# turned up a new stale number. They were not three mistakes: the 2026-07-31
# redeploy changed addresses and suite sizes, and nobody swept the documents
# afterwards. Reading carefully three times found symptoms in the order we
# happened to look. This script looks in a fixed order, every time.
#
#   ./scripts/verify-claims.sh            full run
#   SKIP_TESTS=1 ./scripts/verify-claims.sh   skip the forge runs (fast, ~40s)
#
# Exit 0 = every claim matched. Exit 1 = at least one mismatch, listed above.

set -uo pipefail
cd "$(dirname "$0")/.."

RPC="${ARC_RPC:-https://rpc.testnet.arc.network}"
EXPLORER_API="https://testnet.arcscan.app/api/v2"
FAILURES=0
CHECKS=0

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

ok()   { CHECKS=$((CHECKS+1)); grn "  ok    $*"; }
bad()  { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); red "  FAIL  $*"; }

# The deployment of record. Update this block when contracts are redeployed,
# then run the script: everything that still points at an old address fails.
LIVE_AGENTBOND=0x4383Ea48837eF7e60fC22BD67945BCBf0551702c
LIVE_STREAMPAY=0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262
LIVE_COMMITSTAKEV2=0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474
LIVE_COMMITSTAKE=0xc307d9287707Ba04c03Dd653b4457E949129A9a2

# Addresses that exist on chain but nothing here should present as current.
# A doc may still MENTION them, but only in a superseded/historical context,
# which is why the check below is scoped to present-tense phrasing.
SUPERSEDED=(
  0x1f1CA31bC36a95a3909628F1bA97970E20698CA9   # CommitStakeV2 before 2026-07-31
  0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0   # AgentBond before 2026-07-31
  0x505739d33D85AD85D0f9eeE64856309782382450   # StreamPay before 2026-07-31
)

TRACKED() {
  git ls-files | grep -vE 'node_modules|package-lock|/out/|/cache/|/lib/|\.pdf$|\.png$|\.jpg$'
}

# ---------------------------------------------------------------- suite sizes
head_ "Test suites"
# No associative arrays here on purpose: macOS ships bash 3.2, where
# `declare -A` is a syntax error. A space-delimited list of the measured
# numbers is all the later check needs anyway.
ALLOWED_COUNTS=""
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  echo "  (SKIP_TESTS=1: suites not run, so the document count check is skipped)"
else
  export PATH="$HOME/.foundry/bin:$PATH"
  TOTAL=0
  for p in agent-bond stream-pay commit-stake commit-stake-v2; do
    line=$(cd "contracts/$p" && forge test 2>/dev/null | grep -E '^Ran [0-9]+ test suites' | tail -1)
    n=$(printf '%s' "$line" | sed -nE 's/.*: ([0-9]+) tests passed.*/\1/p')
    f=$(printf '%s' "$line" | sed -nE 's/.*passed, ([0-9]+) failed.*/\1/p')
    if [ -z "$n" ]; then bad "$p: could not parse forge output"; continue; fi
    ALLOWED_COUNTS="$ALLOWED_COUNTS $n"
    TOTAL=$((TOTAL + n))
    if [ "${f:-1}" = "0" ]; then ok "$p: $n tests, 0 failed"; else bad "$p: $f failing tests"; fi
  done
  ALLOWED_COUNTS="$ALLOWED_COUNTS $TOTAL"
  echo "  total: $TOTAL"

  head_ "Test counts quoted in documents"
  # Every "<number> tests" in a document has to be one of the numbers we just
  # measured. A count frozen at a pre-redeploy value is the failure mode that
  # produced a new finding on each of three review passes in one evening.
  TRACKED | grep -E '\.(md|html)$' | while IFS= read -r file; do
    case "$file" in *_AUDIT_2026-*|social/*|CHANGELOG.md) continue;; esac   # dated historical records
    # Four spellings. "N tests" was the original; "N-test" hid a stale 102 in the
    # submission document; "N/N green" hid a stale 88 in three more places. The fourth,
    # "N and M tests", hid a stale 48 in JUDGES.md through the whole 08-05 sweep: only
    # the *last* number in a coordinated list sits next to the word "tests", so every
    # earlier one was invisible to the first three spellings. Each was found by someone
    # reading, after the checker had signed the file off.
    grep -onE '\b[0-9]{2,4}( and [0-9]{2,4})?([ -]tests?\b|/[0-9]{2,4} green)' "$file" 2>/dev/null \
    | sed -E 's/^([0-9]+):([0-9]{2,4}) and ([0-9]{2,4})([ -]tests?|\/.*)$/\1:\2 tests\n\1:\3\4/' \
    | while IFS=: read -r ln hit; do
      num=${hit%%[ -/]*}
      # A number the text itself pins to a past run is a record, not a claim
      # about today. Requires explicit phrasing ("as of that date", "at the
      # time", a YYYY-MM-DD on the line) so this cannot be used to wave
      # through a plain stale number.
      linetext=$(sed -n "${ln}p" "$file")
      if printf '%s' "$linetext" | grep -qiE 'as of (that date|then)|at the time|20[0-9]{2}-[0-9]{2}-[0-9]{2}'; then
        echo "OK|$file:$ln|$hit (dated as historical)"
        continue
      fi
      case " $ALLOWED_COUNTS " in
        *" $num "*) echo "OK|$file:$ln|$hit" ;;
        *)          echo "BAD|$file:$ln|$hit" ;;
      esac
    done
  done > /tmp/vc_counts.txt
  while IFS='|' read -r verdict loc hit; do
    [ -z "${verdict:-}" ] && continue
    if [ "$verdict" = "OK" ]; then ok "$loc  $hit"; else bad "$loc  \"$hit\" is not a measured suite size"; fi
  done < /tmp/vc_counts.txt

  head_ "README suite table"
  # The table states each project's count in a bare cell, with no "tests" word
  # next to it, so the check above cannot see it. That column is where the
  # 187 error actually lived, and a mutation test proved the checker was blind
  # to it: flipping 48 back to 32 passed silently until this block existed.
  for p in agent-bond stream-pay commit-stake commit-stake-v2; do
    stated=$(grep -E "^\| \[\`contracts/$p\`\]" README.md | awk -F'|' '{gsub(/ /,"",$3); print $3}')
    actual=$(cd "contracts/$p" && forge test 2>/dev/null | grep -E '^Ran [0-9]+ test suites' | tail -1 | sed -nE 's/.*: ([0-9]+) tests passed.*/\1/p')
    if [ -z "$stated" ]; then bad "README has no suite-table row for $p"
    elif [ "$stated" = "$actual" ]; then ok "README table $p: $stated"
    else bad "README table $p says $stated, measured $actual"
    fi
  done
fi

# ------------------------------------------------------------------ addresses
head_ "Contract addresses on chain"
code_len() {
  curl -s -m 20 -X POST "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$1\",\"latest\"]}" \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("result","") or ""))' 2>/dev/null || echo 0
}
for pair in "AgentBond:$LIVE_AGENTBOND" "StreamPay:$LIVE_STREAMPAY" "CommitStakeV2:$LIVE_COMMITSTAKEV2" "CommitStake:$LIVE_COMMITSTAKE"; do
  name=${pair%%:*}; addr=${pair#*:}
  len=$(code_len "$addr")
  [ "$len" -gt 4 ] && ok "$name $addr has bytecode ($len hex)" || bad "$name $addr has NO bytecode"
done

head_ "Explorer verification (exact match, from our own source)"
for pair in "AgentBond:$LIVE_AGENTBOND" "StreamPay:$LIVE_STREAMPAY" "CommitStakeV2:$LIVE_COMMITSTAKEV2"; do
  name=${pair%%:*}; addr=${pair#*:}
  # NOTE: this API rejects unknown query params with 422, so cache-bust with a
  # header, never with ?cb=.
  read -r full partial viadb <<<"$(curl -s -m 25 -H 'Cache-Control: no-cache' "$EXPLORER_API/smart-contracts/$addr" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("is_fully_verified"),d.get("is_partially_verified"),d.get("is_verified_via_eth_bytecode_db"))' 2>/dev/null)"
  if [ "$full" = "True" ] && [ "$partial" = "False" ] && [ "$viadb" = "False" ]; then
    ok "$name fully verified from our source (not a bytecode-db match)"
  else
    bad "$name verification is fully=$full partial=$partial via_bytecode_db=$viadb"
  fi
done

head_ "Superseded addresses must not be presented as current"
for old in "${SUPERSEDED[@]}"; do
  short=${old:0:10}
  hits=$(TRACKED | xargs grep -linE "$old" 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "$short… not referenced anywhere"; continue; fi
  for f in $hits; do
    # Present-tense framing next to an old address is the actual defect. A
    # dated correction or a "superseded" heading is fine and stays.
    if grep -inE "(current|active|live|deployed at)[^.]{0,80}$old|$old[^.]{0,80}(is (the )?(current|active|live))" "$f" >/dev/null 2>&1; then
      bad "$f presents $short… as current"
    else
      ok "$f mentions $short… only in a historical context"
    fi
  done
done

# ----------------------------------------------------------------------- URLs
head_ "Links"
TRACKED | grep -E '\.(md|html)$' | xargs grep -ohE 'https://[a-zA-Z0-9./_?=&#:%-]+' 2>/dev/null \
  | sed 's/[.,)`"]*$//' | sort -u \
  | grep -vE 'fonts\.(googleapis|gstatic)|shields\.io|rpc\.testnet\.arc\.network|example\.com' \
  > /tmp/vc_urls.txt
while read -r u; do
  code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$u")
  case "$code" in
    # 3xx is a working link, not a broken one. getfoundry.sh answers 307 and
    # the first version of this script called that a failure, which is exactly
    # the kind of false alarm that trains people to ignore the checker.
    200|301|302|303|307|308) ok "$code $u" ;;
    *)                       bad "$code $u" ;;
  esac
done < /tmp/vc_urls.txt

# --------------------------------------------------------------------- hygiene
head_ "Repository hygiene"
leaked=$(TRACKED | grep -cE '(^|/)\.env$|\.key$|\.pem$|secrets?\.json$' || true)
[ "$leaked" = "0" ] && ok "no .env / key / pem files tracked" || bad "$leaked credential-shaped files are tracked"
nm=$(git ls-files | grep -c 'node_modules/' || true)
[ "$nm" = "0" ] && ok "node_modules not tracked" || bad "$nm node_modules files tracked"
unpushed=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
[ "$unpushed" = "0" ] && ok "nothing unpushed" || bad "$unpushed commits not pushed"

# Nothing above can read a rendered image, so a diagram whose source was
# corrected but never re-exported passes every other check while showing a dead
# project name and three superseded addresses. That is exactly what happened:
# 94b3b5e edited architecture.src.html and left architecture.png untouched, and
# the stale render survived four review passes. Compare the commits, not the
# mtimes, because a fresh clone writes every file at the same moment.
src_c=$(git log -1 --format=%ct -- architecture.src.html 2>/dev/null || echo 0)
png_c=$(git log -1 --format=%ct -- architecture.png 2>/dev/null || echo 0)
if [ "$src_c" = "0" ] || [ "$png_c" = "0" ]; then
  bad "architecture diagram: source or export missing from git"
elif [ "$png_c" -ge "$src_c" ]; then
  ok "architecture.png exported no earlier than its source"
else
  bad "architecture.png predates architecture.src.html, re-export it"
fi

# ---------------------------------------------------------------------- result
head_ "Result"
if [ "$FAILURES" -eq 0 ]; then
  grn "$CHECKS checks, all matched."
  exit 0
fi
red "$CHECKS checks, $FAILURES mismatched. Each FAIL above is a claim reality disagrees with."
exit 1
