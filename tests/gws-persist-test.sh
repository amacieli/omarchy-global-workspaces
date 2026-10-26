#!/bin/bash
# Tests for omarchy-gws-persist (Global Persisted mode) with a stubbed hyprctl.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

FAKE_BIN=$(mktemp -d); STATE_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN" "$STATE_DIR"' EXIT
export HOME="$STATE_DIR" XDG_STATE_HOME="$STATE_DIR/.local/state"
export GWS_DEBOUNCE=0 GWS_PLACE_DELAY=0
OM="$XDG_STATE_HOME/omarchy"; GD="$OM/global-workspaces"
mkdir -p "$GD"
PERSIST="$ROOT/bin/omarchy-gws-persist"
LOG="$STATE_DIR/dispatch.log"
echo '{ "HDMI-A-1": 0, "DP-1": 10, "DP-2": 20 }' > "$OM/monitor-bases.json"

# Stub: clients come from $STATE_DIR/clients.json, monitors fixed.
cat > "$FAKE_BIN/hyprctl" <<STUB
#!/bin/bash
if [[ "\$1" == clients ]]; then cat "$STATE_DIR/clients.json"; exit 0; fi
if [[ "\$1" == monitors ]]; then echo '[{"name":"HDMI-A-1","id":0},{"name":"DP-1","id":1},{"name":"DP-2","id":2}]'; exit 0; fi
echo "\$*" >> "$LOG"
STUB
chmod +x "$FAKE_BIN/hyprctl"
export PATH="$FAKE_BIN:$PATH"

client() { # address class wsid floating
  printf '{"address":"%s","class":"%s","mapped":true,"hidden":false,"floating":%s,"workspace":{"id":%s},"at":[100,200],"size":[800,600]}' "$1" "$2" "$4" "$3"
}

# ── Not in persisted mode: everything is a no-op ─────────────────────────────
echo "[$(client 0xa vivaldi-stable 13 false)]" > "$STATE_DIR/clients.json"
"$PERSIST" snapshot; [[ ! -f $GD/layout.json ]] || fail "snapshot is a no-op without the persisted flag"
pass "no-op when persisted mode is off"
: > "$GD/persisted"

# ── Snapshot: monitor by name, slot from workspace id ────────────────────────
echo "[$(client 0xa vivaldi-stable 13 false),$(client 0xb discord 25 true),$(client 0xc foot -1 false)]" > "$STATE_DIR/clients.json"
"$PERSIST" snapshot
python3 - "$GD/layout.json" <<'PY' || fail "snapshot records monitor name and slot"
import json,sys
e=json.load(open(sys.argv[1]))["entries"]
assert e["vivaldi-stable"][0]["monitor"]=="DP-1" and e["vivaldi-stable"][0]["slot"]==3, e
assert e["discord"][0]["monitor"]=="DP-2" and e["discord"][0]["slot"]==5 and e["discord"][0]["floating"], e
assert "foot" not in e, "special/negative workspaces are ignored"
PY
pass "snapshot records monitor name + slot (ws 13 -> DP-1 slot 3; ws 25 -> DP-2 slot 5)"

# ── Merge-only: closing everything must not erase the layout ─────────────────
echo "[]" > "$STATE_DIR/clients.json"
"$PERSIST" snapshot
python3 -c "import json;e=json.load(open('$GD/layout.json'))['entries'];assert 'discord' in e and 'vivaldi-stable' in e" \
  || fail "empty window list keeps recorded entries"
pass "no windows (e.g. during logout) keeps the recorded layout"

# ── Grace period: a class never loses recorded windows while apps reopen ─────
python3 - "$GD/layout.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["entries"]["vivaldi-stable"]=[d["entries"]["vivaldi-stable"][0], dict(d["entries"]["vivaldi-stable"][0], monitor="DP-2", slot=2)]
json.dump(d,open(p,"w"))
PY
echo "[$(client 0xa vivaldi-stable 11 false)]" > "$STATE_DIR/clients.json"
date +%s > "$GD/session-start"
"$PERSIST" snapshot
python3 -c "import json;v=json.load(open('$GD/layout.json'))['entries']['vivaldi-stable'];assert len(v)==2 and v[0]['slot']==1 and v[1]['monitor']=='DP-2'" \
  || fail "grace period keeps entries beyond the windows currently open"
echo $(( $(date +%s) - 1000 )) > "$GD/session-start"
"$PERSIST" snapshot
python3 -c "import json;v=json.load(open('$GD/layout.json'))['entries']['vivaldi-stable'];assert len(v)==1" \
  || fail "after the grace period a closed window is forgotten"
pass "restore grace period never truncates; afterwards closed windows drop out"

# ── Place ────────────────────────────────────────────────────────────────────
python3 - "$GD/layout.json" <<'PY'
import json,sys
p=sys.argv[1]
json.dump({"version":1,"entries":{
 "vivaldi-stable":[{"monitor":"DP-1","slot":3,"floating":False,"seen":9999999999},
                   {"monitor":"DP-2","slot":2,"floating":False,"seen":9999999999}],
 "discord":[{"monitor":"DP-2","slot":5,"floating":True,"at":[50,60],"size":[700,500],"seen":9999999999}],
 "gone":[{"monitor":"eDP-1","slot":1,"floating":False,"seen":9999999999}]}},open(p,"w"))
PY
echo "[$(client 0xa vivaldi-stable 1 false),$(client 0xb vivaldi-stable 1 false)]" > "$STATE_DIR/clients.json"
rm -f "$LOG"; "$PERSIST" place 0xb
grep -q 'workspace = "22".*address:0xb' "$LOG" || fail "second window of a class takes the second entry" "$(cat "$LOG" 2>/dev/null)"
rm -f "$LOG"; "$PERSIST" place 0xa
grep -q 'workspace = "13".*address:0xa' "$LOG" || fail "first window of a class takes the first entry" "$(cat "$LOG" 2>/dev/null)"
pass "n-th window of a class goes to the n-th recorded monitor/slot"

echo "[$(client 0xd discord 1 false)]" > "$STATE_DIR/clients.json"
rm -f "$LOG"; "$PERSIST" place 0xd
grep -q 'workspace = "25"' "$LOG" && grep -q 'float({ action = "enable"' "$LOG" \
  && grep -q 'resize({ x = 700, y = 500, exact = true' "$LOG" && grep -q 'move({ x = 50, y = 60, exact = true' "$LOG" \
  || fail "floating window gets slot, float state and geometry" "$(cat "$LOG")"
pass "floating windows get their geometry back"

echo "[$(client 0xe gone 1 false),$(client 0xf unknown 1 false)]" > "$STATE_DIR/clients.json"
rm -f "$LOG"; "$PERSIST" place 0xe; "$PERSIST" place 0xf
[[ ! -s $LOG ]] || fail "disconnected monitor / unrecorded class: untouched" "$(cat "$LOG")"
pass "unconnected monitor or unrecorded class leaves the window alone"
