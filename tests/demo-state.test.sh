#!/bin/bash
# bash tests/demo-state.test.sh — the demo data reads in the panel's shape, with live times.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
demo="$here/../demo/accounts.json"
fail() { echo "FAIL: $1"; exit 1; }
mapfile -t lines < <(bash "$here/../bin/demo-state" "$demo" claude codex nope)
[[ ${#lines[@]} == 5 ]] || fail "account list, settings and one line per id"
[[ $(jq '[.[].accounts | length]' -c <<<"${lines[0]}") == "[7,6,2]" ]] || fail "seven Claude, six Codex and two Grok accounts"
now=$(date +%s)
first=$(jq -r '.[0].accounts[0].limits[0].resetsAt' <<<"${lines[0]}")
(( $(date -d "$first" +%s) > now )) || fail "reset times are in the future"
[[ $(jq -r '.[0].accounts[0].limits[0] | has("resetsInMin")' <<<"${lines[0]}") == false ]] || fail "relative keys replaced"
[[ $(jq -r '.resetCredits | has("nextExpiresAt")' <<<"${lines[3]}") == true ]] || fail "banked count gets a deadline"
[[ ${lines[4]} == null ]] || fail "unknown id reads as null"
[[ $(bash "$here/../bin/demo-state" --resets "$demo" | jq '.credits | length') == 5 ]] || fail "banked list"
[[ -z $(grep -oE '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+' "$demo" | grep -v '@example\.com$') ]] || fail "demo data uses only example.com addresses"
echo "demo-state tests passed"
