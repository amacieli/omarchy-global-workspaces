#!/bin/bash
# Recorder drops apps closed during this login (not at shutdown), keeps places during
# the login grace, hides non-apps / names OmaLook through launchers.json, and the
# checklist table is ordered left to right by the monitors setup file.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"
LAYOUT="$DIR/layout.json"
NOW=$(date +%s)
gws_persist_on

keys() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["entries"])))' "$LAYOUT"; }
rec() { printf '{"version":1,"entries":%s}\n' "$1" | gws_layout; }
OLD='"foot":[{"monitor":"DP-1","slot":3,"floating":false,"seen":%s,"launcher":"foot"}]'

# a. closed during this login: dropped
echo 1000 > "$DIR/session-start"
rec "{$(printf "$OLD" 1500),\"vivaldi-stable\":[{\"monitor\":\"DP-2\",\"slot\":2,\"floating\":false,\"seen\":1500,\"launcher\":\"x\"}]}"
gws_clients "$(gws_client 0xb vivaldi-stable 22 false)"
"$GW" snapshot
[[ $(keys) == "vivaldi-stable" ]] || fail "foot was seen this login and is gone: dropped" "$(keys)"
pass "app closed during this login is dropped"

# b. record from an earlier login, never relaunched: kept
rec "{$(printf "$OLD" 500)}"
gws_clients
"$GW" snapshot
[[ $(keys) == "foot" ]] || fail "record from an earlier login is kept" "$(keys)"
pass "record from an earlier login is kept"

# c. shutting down: nothing is dropped
rec "{$(printf "$OLD" 1500)}"
GWS_SHUTDOWN=1 "$GW" snapshot
[[ $(keys) == "foot" ]] || fail "shutdown must not drop records" "$(keys)"
pass "nothing is dropped while shutting down"

# d. login grace: a window that landed on the wrong monitor does not overwrite the record
echo "$NOW" > "$DIR/session-start"
rec "{$(printf "$OLD" 1)}"
gws_clients "$(gws_client 0xa foot 21 false)"
"$GW" snapshot
python3 - "$LAYOUT" <<'PY' || fail "grace keeps the recorded place"
import json, sys
w = json.load(open(sys.argv[1]))["entries"]["foot"][0]
assert w["monitor"] == "DP-1" and w["slot"] == 3, w
PY
echo 1000 > "$DIR/session-start"
"$GW" snapshot
python3 - "$LAYOUT" <<'PY' || fail "after the grace the new place is recorded"
import json, sys
w = json.load(open(sys.argv[1]))["entries"]["foot"][0]
assert w["monitor"] == "DP-2" and w["slot"] == 1, w
PY
pass "login grace protects recorded places; later moves are recorded"

# e. launchers.json: dict override names the app, null hides the class
cat > "$DIR/launchers.json" <<'JSON'
{"org.quickshell":{"command":"/opt/omalook/omalook","name":"OmaLook"},"xdg-desktop-portal-gtk":null}
JSON
echo 1000 > "$DIR/session-start"
rec '{}'
gws_clients "$(gws_client 0xc org.quickshell 23 false)" "$(gws_client 0xd xdg-desktop-portal-gtk 11 true)"
"$GW" snapshot
[[ $(keys) == "org.quickshell" ]] || fail "OmaLook recorded, portal hidden" "$(keys)"
grep -q '"launcher": "/opt/omalook/omalook"' "$LAYOUT" || fail "OmaLook launcher recorded"
pass "launchers.json: OmaLook is recorded, non-app classes hidden"
rm -f "$DIR/launchers.json"

# f. table: left to right by monitors.lua, then AW#; header; no row ids in labels
cat > "$GWS_MONITORS_FILE" <<'LUA'
-- hl.monitor({ output = "HDMI-A-1", position = "99x0" })
hl.monitor({ output = "DP-2",    mode = "a", position = "0x0",    scale = 1 })
hl.monitor({ output = "HDMI-A-1", mode = "b", position = "2560x0", scale = 1 })
hl.monitor({ output = "DP-1",    mode = "c", position = "6400x0", scale = 1 })
LUA
rec '{"vivaldi-stable":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1,"launcher":"v"},{"monitor":"HDMI-A-1","slot":2,"floating":false,"seen":1,"launcher":"v"}],
 "foot":[{"monitor":"DP-2","slot":4,"floating":false,"seen":1,"launcher":"foot"}]}'
gws_clients
out=$(python3 "$ROOT/lib/gws.py" picker-options | cut -f2)
exp=$'  4  │  DP-2      │  Foot\n  2  │  HDMI-A-1  │  Vivaldi\n  1  │  DP-1      │  Vivaldi'
[[ $out == "$exp" ]] || fail "table order is DP-2, HDMI-A-1, DP-1" "$out"
hdr=$(python3 "$ROOT/lib/gws.py" picker-header)
[[ $hdr == "    AW#  │  Monitor   │  App" ]] || fail "header" "$hdr"
printf '%s\n' "  2  │  HDMI-A-1  │  Vivaldi" | python3 "$ROOT/lib/gws.py" picker-ids | grep -qx 'vivaldi-stable#1' || fail "label maps back to its row"
pass "checklist table is ordered left to right and maps labels back to rows"

echo "ALL PASS: gws-prune-table"
