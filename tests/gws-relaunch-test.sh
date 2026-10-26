#!/bin/bash
# Steps 2–3: the recorder's rules, the login picker (dry run, apply), and placement
# that only ever applies to windows the picker started.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"
LAYOUT="$DIR/layout.json"
PENDING="$DIR/pending.json"
gws_persist_on

seed() {
  gws_layout <<'JSON'
{"version":1,"entries":{
 "vivaldi-stable":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1,"launcher":"vivaldi-stable"},
                   {"monitor":"DP-2","slot":2,"floating":false,"seen":1,"launcher":"vivaldi-stable"}],
 "foot":[{"monitor":"DP-2","slot":4,"floating":false,"seen":1,"launcher":"foot"}],
 "steam_app_1113120":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1,"launcher":"steam steam://rungameid/1113120"}]}}
JSON
  rm -f "$PENDING"
  : > "$LOG"
}
rows() { "$GW" relaunch --list; }

# ── step 2: recorder rules ───────────────────────────────────────────────────
gws_clients "$(gws_client 0xa foot 13 false)" "$(gws_client 0xb unknownapp 11 false)" \
            "$(gws_client 0xc hiddenapp 12 false)" "$(gws_client 0xd TUI.tile 21 false)"
"$GW" snapshot
python3 - "$LAYOUT" <<'PY' || fail "recorder keeps resolvable classes only, with monitor/slot/launcher"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert set(e) == {"foot", "TUI.tile"}, sorted(e)
assert e["foot"][0] | {"x": 0} and e["foot"][0]["monitor"] == "DP-1" and e["foot"][0]["slot"] == 3
assert e["foot"][0]["launcher"] == "foot"
assert e["TUI.tile"][0]["launcher"].startswith("foot --app-id=TUI.tile")
PY
pass "recorder: monitor, slot, launcher; unresolved classes skipped"

gws_clients "$(gws_client 0xa foot 13 false)" "$(gws_client 0xb 'VirtualBox Machine' 21 false)"
echo '{"foot": null, "VirtualBox Machine": "omarchy-launch-win11-vbox"}' > "$DIR/launchers.json"
"$GW" snapshot
python3 - "$LAYOUT" <<'PY' || fail "override null hides; override command records"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert "foot" not in e and e["VirtualBox Machine"][0]["launcher"] == "omarchy-launch-win11-vbox", e
PY
rm -f "$DIR/launchers.json"
pass "overrides: null hides, command maps"

# ── step 3: login picker ─────────────────────────────────────────────────────
# Count rule: two recorded, one open -> the open one is 'running', never relaunched.
seed
gws_clients "$(gws_client 0xa vivaldi-stable 13 false)"
rows > "$TMP/list.json"
python3 - "$TMP/list.json" <<'PY' || fail "rows: running/launch states and default ticks"
import json, sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["rows"]}
assert r["vivaldi-stable#0"]["state"] == "running"
assert r["vivaldi-stable#1"]["state"] == "launch" and r["vivaldi-stable#1"]["default"] is True
assert r["foot#0"]["default"] is True
assert r["steam_app_1113120#0"]["side_effect"] is True and r["steam_app_1113120#0"]["default"] is False
PY
pass "rows: count rule, side-effect rows default unticked"

seed; gws_clients
cp "$LAYOUT" "$TMP/before"
"$GW" relaunch --dry-run > "$TMP/dry.txt"
[[ $(gws_count .) == 0 ]] || fail "dry run launched or moved something" "$(cat "$LOG")"
cmp -s "$LAYOUT" "$TMP/before" || fail "dry run changed layout.json"
grep -q 'vivaldi-stable#1' "$TMP/dry.txt" || fail "dry run lists rows"
pass "dry run: lists rows, launches nothing, changes nothing"

# Apply: only the ticked vivaldi row starts; unticked foot and steam lose their records.
seed; gws_clients "$(gws_client 0xa vivaldi-stable 13 false)"
"$GW" relaunch --apply "vivaldi-stable#1" >/dev/null
[[ $(gws_count exec_cmd) == 1 ]] || fail "apply launched $(gws_count exec_cmd) times, want 1" "$(cat "$LOG")"
grep -q 'vivaldi-stable' "$LOG" || fail "the launched command is vivaldi"
python3 - "$LAYOUT" "$PENDING" <<'PY' || fail "apply: unticked rows dismissed, pending written"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert "foot" not in e and "steam_app_1113120" not in e, e
assert len(e["vivaldi-stable"]) == 2
p = json.load(open(sys.argv[2]))
assert [(w["class"], w["monitor"], w["slot"]) for w in p["windows"]] == [("vivaldi-stable", "DP-2", 2)], p
PY
pass "apply: ticked row starts, unticked rows dismissed"

# The picker's window is placed from pending.json.
gws_clients "$(gws_client 0xa vivaldi-stable 13 false)" "$(gws_client 0xn vivaldi-stable 1 false)"
"$GW" place 0xn
[[ $(gws_count 'window.move') == 1 ]] && grep -q 'workspace = "22"' "$LOG" \
  || fail "picker window goes to DP-2 slot 2 (ws 22)" "$(cat "$LOG")"
[[ ! -f $PENDING ]] || fail "pending consumed"
pass "placement: picker window goes to DP-2 slot 2"

# A window the user opens by hand is never placed, even when the layout records its class.
gws_clients "$(gws_client 0xa vivaldi-stable 13 false)" "$(gws_client 0xm vivaldi-stable 1 false)"
: > "$LOG"
"$GW" place 0xm
[[ $(gws_count .) == 0 ]] || fail "manual window was placed or moved" "$(cat "$LOG")"
pass "manual window of a recorded class is not placed"

# Expired pending: nothing placed, file removed.
seed; gws_clients "$(gws_client 0xn vivaldi-stable 1 false)"
echo '{"expires": 1, "windows": [{"class":"vivaldi-stable","monitor":"DP-2","slot":2,"floating":false}]}' > "$PENDING"
"$GW" place 0xn
[[ $(gws_count .) == 0 && ! -f $PENDING ]] || fail "expired pending still placed or kept"
pass "expired pending is ignored and removed"

# All open: nothing to launch; the open rows are untouched.
seed; gws_clients "$(gws_client 0xa vivaldi-stable 13 false)" "$(gws_client 0xb vivaldi-stable 14 false)"
"$GW" relaunch --apply "vivaldi-stable#0" "vivaldi-stable#1" >/dev/null 2>&1
[[ $(gws_count exec_cmd) == 0 ]] || fail "all-open apply launched something" "$(cat "$LOG")"
python3 - "$LAYOUT" <<'PY' || fail "open rows kept; unticked rows (foot, steam) dismissed"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert len(e["vivaldi-stable"]) == 2 and "foot" not in e and "steam_app_1113120" not in e, e
PY
pass "all recorded windows open: nothing launched, open rows kept"

# Two recorded, none open, both ticked -> two launches.
seed; gws_clients
"$GW" relaunch --apply "vivaldi-stable#0" "vivaldi-stable#1" "foot#0" >/dev/null
[[ $(gws_count exec_cmd) == 3 ]] || fail "count rule: want 3 launches" "$(cat "$LOG")"
pass "count rule: nothing open, all ticked -> every record launches"

# Partial multi-window: only #0 ticked; #1 is dismissed from the layout.
seed; gws_clients
"$GW" relaunch --apply "vivaldi-stable#0" >/dev/null
python3 - "$LAYOUT" <<'PY' || fail "partial dismissal removes only the unticked window"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert e["vivaldi-stable"] == [{"monitor": "DP-1", "slot": 3, "floating": False, "seen": 1, "launcher": "vivaldi-stable"}], e
PY
pass "partial dismissal keeps the ticked window's record"

# Side-effect rows launch only when ticked explicitly.
seed; gws_clients
"$GW" relaunch --apply "steam_app_1113120#0" >/dev/null
grep -q 'rungameid/1113120' "$LOG" || fail "explicitly ticked steam row launches" "$(cat "$LOG")"
pass "side-effect row launches when explicitly ticked"

# Launch with nothing ticked dismisses every row (decision 6, stated in the summary).
seed; gws_clients
"$GW" relaunch --apply >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["entries"]=={}' "$LAYOUT" \
  || fail "launch with nothing ticked dismisses all rows"
pass "launch with nothing ticked dismisses every unticked row"

echo "ALL PASS: gws-persist (recorder + picker + placement)"
