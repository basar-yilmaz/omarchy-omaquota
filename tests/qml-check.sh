#!/bin/bash
# bash tests/qml-check.sh — static checks the shell would only report at run time.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
problem() { echo "FAIL: $1"; fail=1; }

# Names the panel declares, plus what Omarchy's Panel base provides.
declared=$( { grep -oE '^\s*(readonly )?property [A-Za-z]+ [A-Za-z_][A-Za-z0-9_]*' Panel.qml | awk '{print $NF}'
              grep -oE '^\s*function [A-Za-z_][A-Za-z0-9_]*' Panel.qml | awk '{print $2}'
              grep -oE '^\s*id: [A-Za-z_][A-Za-z0-9_]*' Panel.qml | awk '{print $2}'
              printf '%s\n' bar settings opened moduleName ipcTarget manageIpc controller setting open close toggle switchPanel x y width height implicitWidth implicitHeight visible
            } | sort -u )

# 1. every root.X is declared
for name in $(grep -oE 'root\.[A-Za-z_][A-Za-z0-9_]*' Panel.qml | sed 's/root\.//' | sort -u); do
  grep -qx "$name" <<<"$declared" || problem "root.$name is used but never declared"
done

# 2. every Model.X is defined in Model.js (QML reads its functions and vars directly)
defined=$(grep -oE '^(function|var) [A-Za-z_][A-Za-z0-9_]*' Model.js | awk '{print $2}' | sort -u)
for name in $(grep -v '^import' Panel.qml | grep -oE 'Model\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/Model\.//' | sort -u); do
  grep -qx "$name" <<<"$defined" || problem "Model.$name is used but not defined in Model.js"
done

# 3. every string key exists in the English catalog
for key in $(grep -oE 'strings\.tn?\("[^"]+"' Panel.qml | sed -E 's/strings\.tn?\("//;s/"$//' | sort -u); do
  jq -e --arg k "$key" 'has($k)' i18n/en.json >/dev/null || problem "string \"$key\" missing from i18n/en.json"
done
jq -e . i18n/en.json >/dev/null || problem "i18n/en.json is not valid JSON"
jq -e . manifest.json >/dev/null || problem "manifest.json is not valid JSON"

# 4. helper scripts parse
for f in bin/apply-settings bin/demo-state tests/*.sh; do bash -n "$f" || problem "$f has a syntax error"; done
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' bin/codex-resets || problem "bin/codex-resets has a syntax error"
node -e 'new Function(require("fs").readFileSync("Model.js","utf8").replace(/^\.pragma library/, ""))' || problem "Model.js has a syntax error"

# 5. nothing temporary left behind
grep -nE '// TEMP|console\.log' Panel.qml && problem "temporary code or console.log left in Panel.qml"

[[ $fail == 0 ]] && echo "qml-check passed"
exit $fail
