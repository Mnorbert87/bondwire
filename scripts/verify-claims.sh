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
LIVE_COMMITSTAKEV2=0x548532aa4B59598188D49b3e74Fdf27aaE127bb6
LIVE_COMMITSTAKE=0xc307d9287707Ba04c03Dd653b4457E949129A9a2

# Addresses that exist on chain but nothing here should present as current.
# A doc may still MENTION them, but only in a superseded/historical context,
# which is why the check below is scoped to present-tense phrasing.
SUPERSEDED=(
  0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474   # CommitStakeV2 before 2026-08-10
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
    # "Ran 10 test suites" is a suite count, not a test count. It only became visible when the
    # v2 suite crossed from 9 suites to 10, because the pattern needs two digits: the check had
    # been blind to the same shape all along. Strip that phrase before matching, do not widen
    # the pattern, so a real "10 tests" claim still fails.
    # No \b here: macOS ships BSD sed, where \b is not a word boundary and the whole
    # substitution silently does nothing. Same class of trap as the bash 3.2 note above.
    sed -E 's/[0-9]+ (test suites)/\1/g' "$file" 2>/dev/null \
    | grep -onE '\b[0-9]{2,4}( and [0-9]{2,4})?([ -]tests?\b|/[0-9]{2,4} green)' 2>/dev/null \
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

# ------------------------------------------------------------ address roster
# Measured gap, 2026-08-06: changing the last hex digit of the live
# CommitStakeV2 address in README.md left this script fully green. Every check
# above asks the chain "does this resolve", and a one-digit typo resolves --
# it is simply a different real address. Liveness is not equality. So the docs
# are also checked against a roster: anything not on it is a typo or a new
# address nobody wrote down, and both deserve a stop.
#
# The regex is boundary-anchored on purpose. A bare {40} also matches the
# first 40 hex characters of every 64-hex transaction hash, which turns 4 tx
# hashes into 4 phantom "addresses" (measured on this repo).
KNOWN_OTHER="
  0x3600000000000000000000000000000000000000  # USDC on Arc (native gas token)
  0x036CbD53842c5426634e7929541eC2318f3dCF7e  # USDC on Base Sepolia
  0x8004A818BFB912233c491871b3d84c89A494BD9e  # ERC-8004 identity registry
  0x8004b663056a597dFFE9EcCC1965a193b7388713  # ERC-8004 reputation registry (proxy)
  0x9758F80455dd2C1b2d33cFfdCE6B26a04ab02bcD  # Acme, the use-case page's hiring party
  0xcA11bde05977b3631167028862bE2a173976CA11  # Multicall3 (canonical)
  0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275  # CCTP MessageTransmitterV2
  0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA  # CCTP TokenMessengerV2
  0x000000000000000000000000000000000000dEaD  # burn address
  0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a  # Aiden, the demo agent (burner)
  0x0D09cA4F24CF66206f66DA1dc200d213327EEbDc  # x402 demo server burner (payTo)
  0x6A74572d5C0311ceA70b475993b040047dbfB96C  # the demo verifier
  0x7AD10237032263216b87a65DAbE7c676dc7B45fB  # the one approved arbiter
  0xdFDaDEb7440f1CE4Cc2f62Aa21BCCe3374bDF46b  # Circle developer-controlled wallet
  0xDBBed9cdFe1eA44789dDD2EA453cbD9252e6d310  # seed run staker
  0x8918E6A86413b13BD2E995308D4F9dB08cEae361  # seed run beneficiary
  0xa49ff45166612a151f57e1cd209dba4e75e14a41  # StreamPay (EURC), predates the redeploy
"
head_ "Documented addresses are all on the known roster"
ROSTER=$(printf ' %s %s %s %s %s %s ' \
  "$LIVE_AGENTBOND" "$LIVE_STREAMPAY" "$LIVE_COMMITSTAKEV2" "$LIVE_COMMITSTAKE" \
  "${SUPERSEDED[*]}" "$(printf '%s' "$KNOWN_OTHER" | sed 's/#.*//')" \
  | tr 'A-F' 'a-f' | tr -s ' \n' '  ')
UNKNOWN=0
# vendor/ is third party code we ship verbatim, not a document making a claim. The ethers
# bundle carries the ENS registry address and the zero address in its own source, and this
# check exists to catch a typo'd Bondwire address, not to audit a dependency.
for a in $(TRACKED | grep -v '^vendor/' | xargs grep -ohE '0x[a-fA-F0-9]{40}([^a-fA-F0-9]|$)' 2>/dev/null \
           | sed -E 's/[^a-fA-F0-9]$//' | tr 'A-F' 'a-f' | sort -u); do
  case "$ROSTER" in
    *" $a "*) : ;;
    *) bad "unknown address $a — a typo, or a new address missing from the roster"
       UNKNOWN=$((UNKNOWN+1)) ;;
  esac
done
VENDORED=$(TRACKED | grep -c '^vendor/' || true)
[ "$UNKNOWN" = 0 ] && ok "every 0x… address in the docs is a known one (${VENDORED} vendored file(s) excluded, third party source)"

# --------------------------------------------------------- transaction roster
# The third blind spot measured 2026-08-06: changing the last hex digit of a
# burn tx hash in JUDGES.md kept the checker green, because that typo is
# another real transaction and the explorer answers 200 for it. What separates
# our transactions from a stranger's is who they were sent to, so the receipt's
# `to` is checked against the same roster (deploys have no `to`, they carry
# `contractAddress` instead).
head_ "Documented transactions were sent to our own contracts"
TX_BAD=0
TX_N=0
for h in $(TRACKED | grep -E '\.(md|html)$' \
           | xargs grep -ohE 'testnet\.arcscan\.app/tx/0x[a-fA-F0-9]{64}' 2>/dev/null \
           | grep -oE '0x[a-fA-F0-9]{64}' | sort -u); do
  TX_N=$((TX_N+1))
  target=$(curl -s -m 25 -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$h\"]}" \
    | python3 -c 'import sys,json
r=(json.load(sys.stdin) or {}).get("result") or {}
print(((r.get("to") or r.get("contractAddress")) or "").lower())' 2>/dev/null)
  if [ -z "$target" ]; then
    bad "${h:0:12}… has no receipt on this chain"
    TX_BAD=$((TX_BAD+1)); continue
  fi
  case "$ROSTER" in
    *" $target "*) : ;;
    *) bad "${h:0:12}… was sent to $target, which is not ours — typo, or an address missing from the roster"
       TX_BAD=$((TX_BAD+1)) ;;
  esac
done
[ "$TX_BAD" = 0 ] && ok "all $TX_N documented Arc transactions target roster addresses"

# ------------------------------------------------------- mutation score claim
# Also measured 2026-08-06: editing the deck's mutation score from 84.0% to
# 94.0% produced zero failures. The number is a headline on the deck and in the
# submission document, and nothing tied it back to the campaign that measured
# it. The campaign file's own history columns are exempt -- old scores belong
# there, that is what makes it a history.
head_ "Mutation score quoted outside the campaign file"
MUT_FILE=contracts/commit-stake-v2/MUTATION_TESTING.md
if [ ! -f "$MUT_FILE" ]; then
  bad "$MUT_FILE is missing, so no mutation score can be verified"
else
  # Last percentage on the Overall row = the current column, not the previous one.
  SCORE=$(grep -E '^\| \*\*Overall' "$MUT_FILE" | head -1 \
          | grep -oE '\([0-9]+\.[0-9]%\)' | tail -1 | tr -d '()%')
  if [ -z "$SCORE" ]; then
    bad "could not parse the Overall row of $MUT_FILE"
  else
    MUT_BAD=0
    for f in $(TRACKED | grep -E '\.(md|html)$' | grep -v "$MUT_FILE"); do
      for pct in $(grep -iE 'mutation' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]%' | tr -d '%'); do
        if [ "$pct" != "$SCORE" ]; then
          bad "$f quotes mutation score $pct% but the campaign measured $SCORE%"
          MUT_BAD=$((MUT_BAD+1))
        fi
      done
    done
    [ "$MUT_BAD" = 0 ] && ok "every quoted mutation score is $SCORE%, as measured"
  fi
fi

# ----------------------------------------------------------------------- URLs
head_ "Links"
TRACKED | grep -E '\.(md|html)$' | xargs grep -ohE 'https://[a-zA-Z0-9./_?=&#:%-]+' 2>/dev/null \
  | sed 's/[.,)`"]*$//' | sort -u \
  | grep -vE 'fonts\.(googleapis|gstatic)|shields\.io|rpc\.testnet\.arc\.network|example\.com' \
  > /tmp/vc_urls.txt
while read -r u; do
  # basescan bot-walls this script: 000 with the default UA, 403 with a browser one. Neither
  # says anything about the transaction. So for that host the claim is checked where it is
  # actually settled, against the Base Sepolia RPC, and the explorer URL is only the wrapper.
  case "$u" in
    *sepolia.basescan.org/tx/*)
      txh=${u##*/tx/}
      st=$(curl -s -m 20 -X POST https://sepolia.base.org -H 'Content-Type: application/json' \
             -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$txh\"]}" \
           | python3 -c 'import sys,json;r=json.load(sys.stdin).get("result");print((r or {}).get("status",""))' 2>/dev/null)
      if [ "$st" = "0x1" ]; then ok "chain status 0x1 (explorer bot-walls this checker) $u"
      else bad "Base Sepolia receipt is not status 0x1 for $u"; fi
      continue ;;
  esac
  code=$(curl -s -m 20 -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}' "$u")
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
