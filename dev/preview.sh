#!/bin/bash
# Preview the login checklist overlay without touching the running shell, the real
# layout or any app (real HOME so the theme loads; XDG_STATE_HOME is the sandbox): a throwaway Quickshell config, a sandbox state dir, a stub hyprctl.
#   dev/preview.sh [SECONDS]     (default 30) — Esc closes it earlier
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$HERE/tests/helpers.sh"
source "$HERE/tests/gws-fixtures.sh"
REAL_HOME=$HOME
gws_env
trap 'rm -rf "$TMP"' EXIT
make_apps "$TMP/apps"
gws_persist_on
gws_layout <<'JSON'
{"version":1,"entries":{
 "vivaldi-stable":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1,"launcher":"vivaldi-stable"},
                   {"monitor":"DP-2","slot":2,"floating":false,"seen":1,"launcher":"vivaldi-stable"}],
 "foot":[{"monitor":"DP-2","slot":4,"floating":false,"seen":1,"launcher":"foot"}],
 "steam_app_1113120":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1,"launcher":"steam steam://rungameid/1113120"}]}}
JSON
gws_clients
CFG="$TMP/qs"; mkdir -p "$CFG"
for d in Commons Ui services; do ln -s /usr/share/omarchy/shell/$d "$CFG/$d"; done
ln -s "$HERE/picker" "$CFG/picker"
cat > "$CFG/shell.qml" <<QML
import Quickshell
import QtQuick
import "picker"
ShellRoot { Picker { Component.onCompleted: open('{"root":"$HERE"}') } }
QML
echo "state: $TMP (stub hyprctl on PATH, nothing real is launched)" >&2
HOME="$REAL_HOME" PATH="$TMP/bin:$PATH" timeout "${1:-30}" quickshell -p "$CFG" 2>&1 || true
echo "--- hyprctl calls:" >&2; cat "$LOG" >&2 || true
