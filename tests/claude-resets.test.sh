#!/bin/bash
# bash tests/claude-resets.test.sh — bin/claude-resets' parsing and its offline errors; never touches the network.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail() { echo "FAIL: $1"; exit 1; }

out=$(python3 -I - "$here/../bin/claude-resets" <<'PY'
import importlib.machinery, importlib.util, json, sys
from datetime import datetime, timezone
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("claude_resets", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("claude_resets", loader))
loader.exec_module(mod)
now = datetime(2026, 11, 13, tzinfo=timezone.utc)
block = {"eligible": True, "grants": [
  {"label": "Late", "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "starts_at": "2026-11-09T18:00:00+00:00", "type": "full", "paused": False},
  {"label": "Soon <b>x</b>", "resets_left": 2, "ends_at": "2026-12-10T22:00:00+00:00", "type": "full"},
  {"label": "Spent", "resets_left": 0, "ends_at": "2026-12-01T00:00:00+00:00"},
  {"label": "Lapsed", "resets_left": 1, "ends_at": "2026-11-01T00:00:00+00:00"},
  {"label": "Paused", "resets_left": 1, "ends_at": "2026-12-01T00:00:00+00:00", "paused": True},
  {"label": "No deadline", "resets_left": 1, "ends_at": None, "id": "secret"},
  "junk", None]}
print(json.dumps(mod.clean(block, now)))
print(json.dumps(mod.clean(None, now)))
PY
)
[[ $(sed -n 1p <<<"$out" | jq -c '[.[].title]') == '["Soon <b>x</b>","Soon <b>x</b>","Late","No deadline"]' ]] || fail "available only, one per reset left, soonest deadline first, no deadline last"
[[ $(sed -n 1p <<<"$out" | jq -r '.[0].status, .[2].grantedAt' | paste -sd' ') == "available 2026-11-09T18:00:00+00:00" ]] || fail "status and start kept"
[[ $(sed -n 1p <<<"$out" | jq -r '.[3] | has("id")') == false ]] || fail "only display fields"
[[ $(sed -n 2p <<<"$out") == "[]" ]] || fail "no block means no credits"

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
[[ $(python3 -I "$here/../bin/claude-resets" "$home" | jq -r .error) == "no Claude sign-in found" ]] || fail "missing sign-in reported"
echo '{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}' >"$home/.credentials.json"
[[ $(python3 -I "$here/../bin/claude-resets" "$home" | jq -r .error) == "Limits paused"* ]] || fail "lapsed token reported, not sent"
echo "claude-resets tests passed"
