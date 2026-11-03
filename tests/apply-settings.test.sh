#!/bin/bash
# bash tests/apply-settings.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
apply="$here/../bin/apply-settings"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

printf '{"theme":"dark","remoteControlAtStartup":false,"hooks":{"a":1}}' >"$dir/settings.json"
chmod 640 "$dir/settings.json"
"$apply" "$dir/settings.json" '{"remoteControlAtStartup":true}' || fail "apply"
[[ $(jq -c . "$dir/settings.json") == '{"theme":"dark","remoteControlAtStartup":true,"hooks":{"a":1}}' ]] || fail "merge kept other keys"
[[ $(stat -c %a "$dir/settings.json") == 640 ]] || fail "mode kept"

before=$(cat "$dir/settings.json")
"$apply" "$dir/settings.json" '{"x":"str"}' 2>/dev/null && fail "non-boolean accepted"
"$apply" "$dir/settings.json" '{"a b":true}' 2>/dev/null && fail "bad key accepted"
"$apply" "$dir/settings.json" '{}' 2>/dev/null && fail "empty overlay accepted"
"$apply" "$dir/other.json" '{"x":true}' 2>/dev/null && fail "wrong file name accepted"
ln -s "$dir/settings.json" "$dir/link" && mkdir "$dir/l" && ln -s "$dir/settings.json" "$dir/l/settings.json"
"$apply" "$dir/l/settings.json" '{"x":true}' 2>/dev/null && fail "symlink accepted"
[[ $(cat "$dir/settings.json") == "$before" ]] || fail "rejected calls changed the file"

printf 'not json' >"$dir/settings.json"
"$apply" "$dir/settings.json" '{"x":true}' 2>/dev/null && fail "broken file overwritten"
[[ $(cat "$dir/settings.json") == "not json" ]] || fail "broken file left alone"
[[ -z $(ls -A "$dir" | grep omaquota) ]] || fail "temp file left behind"
echo "apply-settings tests passed"
