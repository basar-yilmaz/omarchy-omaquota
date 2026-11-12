#!/bin/bash
# bash tests/run-all.sh — every automated check; run before each release.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
run() { echo "== $*"; "$@" || status=1; }
run bash tests/qml-check.sh
run node tests/model.test.js
run bash tests/apply-settings.test.sh
run bash tests/codex-resets.test.sh
run bash tests/claude-resets.test.sh
run bash tests/demo-state.test.sh
run omarchy plugin validate .
[[ $status == 0 ]] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $status
