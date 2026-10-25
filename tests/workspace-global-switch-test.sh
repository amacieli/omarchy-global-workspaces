#!/bin/bash
# Tests for omarchy-hyprland-workspace-global-switch — run without a compositor.
# hyprctl is stubbed with a fixed monitor snapshot; dispatches are logged.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

FAKE_BIN=$(mktemp -d)
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN" "$STATE_DIR"' EXIT

export HOME="$STATE_DIR"
export XDG_STATE_HOME="$STATE_DIR/.local/state"
BASES_FILE="$XDG_STATE_HOME/omarchy/monitor-bases.json"
mkdir -p "$(dirname "$BASES_FILE")"
DISPATCH_LOG="$STATE_DIR/dispatch.log"
SWITCH="$ROOT/bin/omarchy-hyprland-workspace-global-switch"

# make_hyprctl_stub <focused> <ws-eDP> <ws-HDMI> <ws-DP1> [apply]
# Monitors: eDP-1 (id0) HDMI-A-1 (id1) DP-1 (id2), each on the given workspace id.
# With "apply", dispatching `focus({ workspace = "N" })` moves the monitor whose
# range owns N (as the real hook would); otherwise the snapshot never changes.
make_hyprctl_stub() {
  local focused="$1" w0="$2" w1="$3" w2="$4"
  cat > "$FAKE_BIN/hyprctl" <<STUB
#!/bin/bash
if [[ "\$1" == "monitors" && "\$2" == "-j" ]]; then
  python3 - <<PY
import json
f="$focused"
print(json.dumps([
 {"name":"eDP-1","id":0,"focused":f=="eDP-1","activeWorkspace":{"id":$w0}},
 {"name":"HDMI-A-1","id":1,"focused":f=="HDMI-A-1","activeWorkspace":{"id":$w1}},
 {"name":"DP-1","id":2,"focused":f=="DP-1","activeWorkspace":{"id":$w2}}]))
PY
  exit 0
fi
echo "\$*" >> "$DISPATCH_LOG"
STUB
  chmod +x "$FAKE_BIN/hyprctl"
}

export PATH="$FAKE_BIN:$PATH"

# ── Slot validation ───────────────────────────────────────────────────────────
make_hyprctl_stub eDP-1 1 11 21
for bad in 0 11 ""; do
  status=0
  "$SWITCH" "$bad" 2>/dev/null || status=$?
  (( status != 0 )) || fail "slot '$bad' is rejected"
  pass "slot '$bad' is rejected"
done

# ── No bases file → raw slot fallback ────────────────────────────────────────
rm -f "$DISPATCH_LOG"
"$SWITCH" 3 2>/dev/null || true
grep -q 'workspace = "3"' "$DISPATCH_LOG" || fail "no bases file falls back to raw slot dispatch"
pass "no bases file falls back to raw slot dispatch"

cat > "$BASES_FILE" <<'JSON'
{ "DP-1": 20, "HDMI-A-1": 10, "eDP-1": 0 }
JSON

# ── Hook already synced everything (focused = HDMI-A-1): exactly one dispatch ─────
make_hyprctl_stub HDMI-A-1 2 12 22
rm -f "$DISPATCH_LOG"
"$SWITCH" 2 2>/dev/null || true
[[ $(wc -l < "$DISPATCH_LOG") == 1 ]] || fail "normal path is a single dispatch" "$(cat "$DISPATCH_LOG")"
grep -q 'workspace = "12"' "$DISPATCH_LOG" || fail "single dispatch targets focused monitor's base+slot" "$(cat "$DISPATCH_LOG")"
pass "no per-monitor fan-out: one dispatch for the focused monitor (workspace 12)"

# ── Hook did its job (others already on slot 2 after the dispatch): no heal ──
make_hyprctl_stub eDP-1 2 12 22
rm -f "$DISPATCH_LOG"
"$SWITCH" 2 2>/dev/null || true
[[ $(wc -l < "$DISPATCH_LOG") == 1 ]] || fail "synced monitors are not touched" "$(cat "$DISPATCH_LOG")"
pass "monitors already on the target slot are skipped"

# ── Out-of-sync monitor is healed: monitor focused first, then workspace ─────
# Snapshot never changes, so after the first dispatch DP-1 (21) is still off
# slot 3 → heal DP-1 (monitor first), then restore eDP-1.
make_hyprctl_stub eDP-1 3 13 21
rm -f "$DISPATCH_LOG"
"$SWITCH" 3 2>/dev/null || true
mapfile -t lines < "$DISPATCH_LOG"
[[ ${lines[0]} == *'workspace = "3"'* ]]   || fail "heal: primary dispatch first" "$(cat "$DISPATCH_LOG")"
[[ ${lines[1]} == *'monitor = "DP-1"'* ]]  || fail "heal: lagging monitor focused before its workspace" "$(cat "$DISPATCH_LOG")"
[[ ${lines[2]} == *'workspace = "23"'* ]]  || fail "heal: lagging monitor dispatched to base+slot" "$(cat "$DISPATCH_LOG")"
[[ ${lines[-1]} == *'monitor = "eDP-1"'* ]] || fail "heal: originating monitor refocused last" "$(cat "$DISPATCH_LOG")"
pass "lagging monitor healed monitor-first, originating monitor restored last"

# ── Focused monitor not in bases → raw fallback ──────────────────────────────
cat > "$BASES_FILE" <<'JSON'
{ "DP-1": 20, "HDMI-A-1": 10 }
JSON
make_hyprctl_stub eDP-1 1 11 21
rm -f "$DISPATCH_LOG"
"$SWITCH" 4 2>/dev/null || true
grep -q 'workspace = "4"' "$DISPATCH_LOG" || fail "unknown focused monitor falls back to raw slot"
pass "unknown focused monitor falls back to raw slot"
