#!/bin/bash
# Login checklist (omarchy-gws-picker) with a stand-in gum: what it offers, what it does with the answer.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
PICKER="$ROOT/bin/omarchy-gws-picker"
LAYOUT="$DIR/layout.json"
export GWS_GUM="$TMP/bin/gum" GWS_TEST_DIR="$TMP"

# Stand-in gum: records its arguments, prints GWS_TEST_PICK for 'choose', exits with GWS_TEST_EXIT / GWS_TEST_CONFIRM.
cat > "$TMP/bin/gum" <<'GUM'
#!/bin/bash
echo "$*" >> "$GWS_TEST_DIR/gum.args"
case "$1" in
  choose) cat > "$GWS_TEST_DIR/gum.options"; printf '%b' "${GWS_TEST_PICK:-}"; exit "${GWS_TEST_EXIT:-0}" ;;
  confirm) exit "${GWS_TEST_CONFIRM:-1}" ;;
esac
GUM
chmod +x "$TMP/bin/gum"

seed() {
  gws_layout <<'JSON'
{"version":1,"entries":{
 "vivaldi-stable":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1,"launcher":"vivaldi-stable"},
                   {"monitor":"DP-2","slot":2,"floating":false,"seen":1,"launcher":"vivaldi-stable"}],
 "foot":[{"monitor":"DP-2","slot":4,"floating":false,"seen":1,"launcher":"foot"}],
 "steam_app_1113120":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1,"launcher":"steam steam://rungameid/1113120"}]}}
JSON
  rm -f "$TMP/gum.args" "$TMP/gum.options" "$DIR/pending.json"
  gws_persist_on
  : > "$LOG"
  gws_clients
}
gws_persist_on

# 1. Offers the launchable rows; ticks the default ones; side-effect Steam starts unticked.
seed
GWS_TEST_PICK='3          │  DP-1     │  Vivaldi\n' "$PICKER" >/dev/null
grep -q 'IXION' "$TMP/gum.options" || fail "steam row is offered" "$(cat "$TMP/gum.options")"
grep -q -- '--selected' "$TMP/gum.args" || fail "defaults are passed as --selected" "$(cat "$TMP/gum.args")"
grep -q '3          │  DP-1     │  Vivaldi' "$TMP/gum.args" && grep -q '4          │  DP-2     │  Foot' "$TMP/gum.args" \
  || fail "default rows are ticked" "$(cat "$TMP/gum.args")"
if grep -q 'IXION' "$TMP/gum.args"; then fail "steam row is not ticked by default" "$(cat "$TMP/gum.args")"; fi
pass "offers launchable rows; defaults ticked; side-effect row unticked"

# 2. Ticking one vivaldi row: that row launches, the rest are dismissed from the record.
seed
GWS_TEST_PICK='3          │  DP-1     │  Vivaldi\n' "$PICKER" >/dev/null
[[ $(gws_count exec_cmd) == 1 ]] || fail "one ticked row launches once" "$(cat "$LOG")"
python3 - "$LAYOUT" <<'PY' || fail "unticked foot and steam dismissed; ticked row kept"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert "foot" not in e and "steam_app_1113120" not in e, e
assert len(e["vivaldi-stable"]) == 1 and e["vivaldi-stable"][0]["monitor"] == "DP-1"
PY
pass "ticked row launches, unticked rows dismissed"

# 3. Esc: nothing launched, nothing changed.
seed
cp "$LAYOUT" "$TMP/before"
GWS_TEST_EXIT=130 "$PICKER" >/dev/null
cmp -s "$LAYOUT" "$TMP/before" && [[ $(gws_count exec_cmd) == 0 ]] || fail "Esc changes nothing" "$(cat "$LOG")"
pass "Esc leaves everything as it was"

# 4. Enter with nothing ticked: confirm 'no' keeps the records; confirm 'yes' dismisses them.
seed
cp "$LAYOUT" "$TMP/before"
GWS_TEST_PICK='' GWS_TEST_CONFIRM=1 "$PICKER" >/dev/null
cmp -s "$LAYOUT" "$TMP/before" || fail "empty Enter, declined, changes nothing"
GWS_TEST_PICK='' GWS_TEST_CONFIRM=0 "$PICKER" >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["entries"]=={}' "$LAYOUT" \
  || fail "empty Enter, confirmed, dismisses all"
pass "empty Enter asks first"

# 5. Not in persisted mode: no checklist at all.
seed
rm -f "$DIR/persisted"
"$PICKER" >/dev/null
[[ ! -f $TMP/gum.args ]] || fail "no checklist outside persisted mode"
pass "no checklist outside persisted mode"

# 6. The real gum, under a pseudo-terminal: Enter launches the defaults and dismisses the rest.
seed
rc=$(GWS_GUM=/usr/bin/gum python3 "$HERE/gws-pty.py" "$PICKER" ENTER)
[[ $rc == 0 ]] || fail "pty: Enter exits 0" "rc=$rc"
[[ $(gws_count exec_cmd) == 3 ]] || fail "pty: Enter launches the 3 defaults (2 vivaldi, foot)" "$(cat "$LOG")"
python3 - "$LAYOUT" <<'PY' || fail "pty: steam dismissed, both vivaldi kept"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert "steam_app_1113120" not in e and len(e["vivaldi-stable"]) == 2 and "foot" in e, e
PY
pass "pty (real gum): Enter launches the defaults and dismisses the rest"

# 7. The real gum: the first row is the unticked Steam row; DOWN moves to Vivaldi DP-2 slot 2, x unticks it, Enter launches what is left.
seed
rc=$(GWS_GUM=/usr/bin/gum python3 "$HERE/gws-pty.py" "$PICKER" DOWN x ENTER)
[[ $rc == 0 ]] || fail "pty: space+enter exits 0" "rc=$rc"
[[ $(gws_count exec_cmd) == 2 ]] || fail "pty: one untick leaves 2 launches" "$(cat "$LOG")"
python3 - "$LAYOUT" <<'PY' || fail "pty: the cursor row (Vivaldi, DP-2 slot 2) dismissed"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
assert "steam_app_1113120" not in e and "foot" in e, e
assert [w["monitor"] for w in e["vivaldi-stable"]] == ["DP-1"], e
PY
grep -q 'exec_cmd("foot")' "$LOG" || fail "pty: the ticked foot row is launched"
[[ $(grep -c 'exec_cmd("vivaldi-stable")' "$LOG" || true) == 1 ]] || fail "pty: only the DP-1 vivaldi row launches"
pass "pty (real gum): x unticks the cursor row, Enter launches the rest"

# 8. The real gum: Ctrl-C leaves everything alone.
seed
cp "$LAYOUT" "$TMP/before"
rc=$(GWS_GUM=/usr/bin/gum python3 "$HERE/gws-pty.py" "$PICKER" CTRL_C)
[[ $rc == 0 ]] || fail "pty: ctrl-c exits 0" "rc=$rc"
cmp -s "$LAYOUT" "$TMP/before" && [[ $(gws_count exec_cmd) == 0 ]] || fail "pty: ctrl-c changes nothing"
pass "pty (real gum): Ctrl-C leaves everything alone"

# 9. The login hook, run through the real Lua template with a stub hl API:
#    the picker is started only in persisted mode, and only from hyprland.start.
lua_hook() {  # loads the rendered template, fires hyprland.start, prints recorded commands
  cat > "$TMP/run.lua" <<'LUA'
local handlers, cmds = {}, {}
os.execute = function(c) cmds[#cmds + 1] = c; return 0 end
local function stub()
  return setmetatable({}, { __index = function() return stub() end,
                            __call = function() return stub() end })
end
hl = setmetatable({ on = function(name, f) handlers[name] = f end },
  { __index = function() return stub() end })
dofile(arg[1])
cmds = {}
if handlers["hyprland.start"] then handlers["hyprland.start"]() end
for _, c in ipairs(cmds) do print(c) end
LUA
  lua "$TMP/run.lua" "$TMP/ws.lua" 2>/dev/null
}
sed "s#@PLUGIN_DIR@#$ROOT#g" "$ROOT/hypr/workspace-global.lua" > "$TMP/ws.lua"
luac -p "$TMP/ws.lua" || fail "rendered Lua template parses"

rm -f "$DIR/persisted"
out=$(lua_hook)
[[ -z $(grep -F 'omarchy-gws-picker' <<<"$out") ]] || fail "hook: no picker outside persisted mode" "$out"
touch "$DIR/persisted"
out=$(lua_hook)
grep -q 'omarchy-gws-picker' <<<"$out" || fail "hook: picker starts at hyprland.start in persisted mode" "$out"
grep -q 'sleep 4' <<<"$out" || fail "hook: picker waits before it opens" "$out"
grep -q 'session-start' <<<"$out" || fail "hook: session-start still runs" "$out"
pass "login hook: picker runs once per start, persisted mode only, after session-start"

# 10. The on-demand route and the README menu snippet.
rm -f "$DIR/persisted"
rc=0; "$ROOT/bin/omarchy-global-workspaces" relaunch >/dev/null 2>&1 || rc=$?
[[ $rc == 0 ]] || fail "relaunch route exits 0 outside persisted mode" "rc=$rc"
gws_persist_on
python3 - "$ROOT/README.md" <<'PY' || fail "README menu snippet is valid JSON"
import json, re, sys
text = open(sys.argv[1]).read()
block = re.search(r"### Relaunch picker on demand.*?```jsonc\n(.*?)```", text, re.S).group(1)
json.loads("{" + block + "}")
PY
pass "relaunch route exits cleanly outside persisted mode; README snippet parses"

echo "ALL PASS: gws-picker"
