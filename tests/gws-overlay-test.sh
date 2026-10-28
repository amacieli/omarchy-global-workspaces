#!/bin/bash
# Login checklist overlay, everything except the QML drawing (see dev/preview.sh for that):
# picker-json rows, the summon script's wait/retry, the login hook, and the manifest.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
SUMMON="$ROOT/bin/omarchy-gws-summon"
GWS="$ROOT/lib/gws.py"

seed() {
  gws_layout <<'JSON'
{"version":1,"entries":{
 "vivaldi-stable":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1,"launcher":"vivaldi-stable"},
                   {"monitor":"DP-2","slot":2,"floating":false,"seen":1,"launcher":"vivaldi-stable"}],
 "foot":[{"monitor":"DP-2","slot":4,"floating":false,"seen":1,"launcher":"foot"}],
 "steam_app_1113120":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1,"launcher":"steam steam://rungameid/1113120"}]}}
JSON
  gws_persist_on
  : > "$LOG"
  gws_clients
}

# 1. picker-json: sorted by workspace slot, ids straight from the rows, side-effect row unticked.
seed
python3 "$GWS" picker-json | python3 -c '
import json, sys
rows = json.load(sys.stdin)["rows"]
assert [r["workspace"] for r in rows] == [1, 2, 3, 4], rows
assert [r["id"] for r in rows] == ["steam_app_1113120#0", "vivaldi-stable#1", "vivaldi-stable#0", "foot#0"], rows
assert [r["on"] for r in rows] == [False, True, True, True], rows
assert rows[0]["sideEffect"] and not rows[1]["sideEffect"], rows
assert rows[1]["monitor"] == "DP-2" and rows[1]["app"] == "Vivaldi" and rows[1]["connected"], rows
' || fail "picker-json rows, order, ticks, side effect"
pass "picker-json: rows sorted by slot, ids carried, Steam/VM unticked"

# 2. Rows that are already open are not offered.
gws_clients "$(gws_client 0x1 foot 24 false)"
python3 "$GWS" picker-json | python3 -c '
import json, sys
ids = [r["id"] for r in json.load(sys.stdin)["rows"]]
assert "foot#0" not in ids and len(ids) == 3, ids
' || fail "open windows are not offered"
pass "picker-json: an app that is already open is not offered"

# 3. The ids picker-json hands out are the ids --apply understands: tick one, the rest are dismissed.
seed
id=$(python3 "$GWS" picker-json | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][2]["id"])')
"$ROOT/bin/omarchy-gws-persist" relaunch --apply "$id" >/dev/null
[[ $(gws_count exec_cmd) == 1 ]] || fail "one ticked id launches once" "$(cat "$LOG")"
python3 - "$DIR/layout.json" <<'PY' || fail "unticked rows dismissed, ticked row kept"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert list(e) == ["vivaldi-stable"] and len(e["vivaldi-stable"]) == 1, e
PY
pass "picker-json ids round-trip through relaunch --apply"

# 4. The summon script: stand-in omarchy-shell logs calls; ping answers after N misses, summon after M.
cat > "$TMP/bin/omarchy-shell" <<'SH'
#!/bin/bash
echo "$*" >> "$GWS_TEST_DIR/shell.calls"
case "$2" in
  ping)   n=$(grep -c ' ping' "$GWS_TEST_DIR/shell.calls"); (( n > ${GWS_TEST_PING_MISSES:-0} )) && echo ok ;;
  summon) n=$(grep -c ' summon' "$GWS_TEST_DIR/shell.calls"); (( n > ${GWS_TEST_SUMMON_MISSES:-0} )) && echo ok || echo unknown ;;
esac
SH
chmod +x "$TMP/bin/omarchy-shell"
export GWS_TEST_DIR="$TMP" GWS_SHELL_CMD="$TMP/bin/omarchy-shell" GWS_SUMMON_DELAY=0 GWS_SUMMON_WAIT=0 GWS_SUMMON_TRIES=5
ID=io.github.amacieli.global-workspaces

rm -f "$DIR/persisted" "$TMP/shell.calls"
"$SUMMON"; [[ ! -e $TMP/shell.calls ]] || fail "summon: nothing happens outside persisted mode" "$(cat "$TMP/shell.calls")"
gws_persist_on
"$SUMMON"
[[ $(grep -c ' summon' "$TMP/shell.calls") == 1 ]] && grep -q "shell summon $ID {}" "$TMP/shell.calls" \
  || fail "summon: opens this plugin's overlay once" "$(cat "$TMP/shell.calls")"
pass "summon: nothing outside persisted mode; one summon of the plugin id when the shell is up"

rm -f "$TMP/shell.calls"
GWS_TEST_PING_MISSES=3 "$SUMMON"
[[ $(grep -c ' ping' "$TMP/shell.calls") == 4 && $(grep -c ' summon' "$TMP/shell.calls") == 1 ]] \
  || fail "summon: waits for the shell to answer ping before summoning" "$(cat "$TMP/shell.calls")"
pass "summon: polls ping until the shell answers, then summons"

rm -f "$TMP/shell.calls"
GWS_TEST_SUMMON_MISSES=2 "$SUMMON"
[[ $(grep -c ' summon' "$TMP/shell.calls") == 3 ]] || fail "summon: retries while the plugin is unknown" "$(cat "$TMP/shell.calls")"
pass "summon: retries 'unknown' until the plugin is loaded"

rm -f "$TMP/shell.calls" "$DIR/summon.log"
rc=0; GWS_TEST_SUMMON_MISSES=99 "$SUMMON" || rc=$?
[[ $rc == 1 && -s $DIR/summon.log ]] || fail "summon: gives up with a log line" "rc=$rc $(cat "$DIR/summon.log" 2>/dev/null)"
pass "summon: gives up after the retry budget and logs why"

# 5. The login hook starts the summon script (not a terminal), persisted mode only.
cat > "$TMP/run.lua" <<'LUA'
local handlers, cmds = {}, {}
os.execute = function(c) cmds[#cmds + 1] = c; return 0 end
local function stub()
  return setmetatable({}, { __index = function() return stub() end, __call = function() return stub() end })
end
hl = setmetatable({ on = function(name, f) handlers[name] = f end }, { __index = function() return stub() end })
dofile(arg[1])
cmds = {}
if handlers["hyprland.start"] then handlers["hyprland.start"]() end
for i = 1, #cmds do print(cmds[i]) end
LUA
sed "s#@PLUGIN_DIR@#$ROOT#g" "$ROOT/hypr/workspace-global.lua" > "$TMP/ws.lua"
rm -f "$DIR/persisted"
[[ -z $(lua "$TMP/run.lua" "$TMP/ws.lua" 2>/dev/null | grep -F omarchy-gws-summon) ]] || fail "hook: silent outside persisted mode"
gws_persist_on
out=$(lua "$TMP/run.lua" "$TMP/ws.lua" 2>/dev/null)
grep -q "$ROOT/bin/omarchy-gws-summon" <<<"$out" || fail "hook: summons the overlay by absolute path" "$out"
grep -q 'session-start' <<<"$out" || fail "hook: session-start still runs" "$out"
pass "login hook: summon script by absolute path, persisted mode only"

# 6. Manifest: both kinds, every entry point exists.
python3 - "$ROOT" <<'PY' || fail "manifest declares bar-widget + overlay with real entry points"
import json, os, sys
root = sys.argv[1]
m = json.load(open(os.path.join(root, "manifest.json")))
assert set(m["kinds"]) == {"bar-widget", "overlay"}, m["kinds"]
for key in ("barWidget", "overlay"):
    assert os.path.isfile(os.path.join(root, m["entryPoints"][key])), key
PY
pass "manifest: bar-widget + overlay, entry points exist"

echo "ALL PASS: gws-overlay"
