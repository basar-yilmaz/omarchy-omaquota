#!/bin/bash
# bash tests/codex-resets.test.sh — runs bin/codex-resets against a fake app-server.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(PATH="$here/fake-codex:$PATH" timeout 20 python3 -I "$here/../bin/codex-resets" /nonexistent-home)
fail() { echo "FAIL: $1"; echo "$out"; exit 1; }
[[ $(jq '.credits | length' <<<"$out") == 3 ]] || fail "three credits"
# Every credit comes back (the panel keeps the available ones), soonest deadline first.
[[ $(jq -c '[.credits[].title]' <<<"$out") == '["Used one","<b>Early</b>","Full reset"]' ]] || fail "soonest deadline first"
[[ $(jq -r '.credits[0].expiresAt' <<<"$out") == "2026-09-21T"* ]] || fail "milliseconds converted"
[[ $(jq -r '.credits[1].expiresAt' <<<"$out") == "2026-11-06T22:13:50+00:00" ]] || fail "ISO deadline kept"
[[ $(jq -r '.credits[2].expiresAt' <<<"$out") == "2026-11-30T"* ]] || fail "seconds converted"
[[ $(jq -r '.credits[0] | has("description") or has("id")' <<<"$out") == false ]] || fail "only display fields"
out=$(PATH="/usr/bin:/bin" timeout 10 python3 -I "$here/../bin/codex-resets")
[[ $(jq -r '.error' <<<"$out") == "codex not found in PATH" ]] || fail "missing codex reported"
echo "codex-resets tests passed"
