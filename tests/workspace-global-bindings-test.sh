#!/bin/bash
# Keybindings registered by hypr/workspace-global.lua, plus end-to-end routing
# of the wrappers they call. No Hyprland session required.
#
#   1. Binding inspection: the toggle file unbinds and rebinds every workspace
#      key to a plugin wrapper, and never binds a key it has not unbound.
#   2. End-to-end routing: the wrappers follow the global/local flag.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

require_command lua

# ── 1. Binding inspection ─────────────────────────────────────────────────────
# Run the template under a stub `hl` that records hl.unbind / hl.bind calls.
# The stub reports one monitor; HYPRLAND_INSTANCE_SIGNATURE gates the live path.
PLUGIN_DIR="/opt/gws test's plugin"   # exercises path quoting

capture() {
  local template="$1"
  GWS_TEMPLATE="$template" GWS_PLUGIN_DIR="$PLUGIN_DIR" HYPRLAND_INSTANCE_SIGNATURE=test \
    HOME=/nonexistent lua << 'LUA'
local f = assert(io.open(os.getenv("GWS_TEMPLATE")))
local src = f:read("*a"); f:close()
src = src:gsub("@PLUGIN_DIR@", function() return os.getenv("GWS_PLUGIN_DIR") end)

local log = {}
local function noop() end
hl = {
  get_monitors = function() return {} end,
  workspace_rule = noop,
  on = noop,
  unbind = function(keys) log[#log + 1] = "UNBIND|" .. keys end,
  bind = function(keys, action, opts)
    log[#log + 1] = "BIND|" .. keys .. "|" .. tostring(action) .. "|" .. tostring(opts and opts.description)
  end,
  dsp = {
    exec_cmd = function(cmd) return "exec:" .. cmd end,
    focus = function(a) return "focus:" .. tostring(a.workspace) end,
  },
}
-- Keep the file from touching the real state dir or spawning helpers.
os.execute = noop
io.open = function(path, mode)
  if mode == "w" then return nil end
  return nil
end

assert(load(src, "workspace-global.lua"))()
for i = 1, #log do print(log[i]) end
LUA
}

output=$(capture "$ROOT/hypr/workspace-global.lua")
q="'/opt/gws test'\\''s plugin/bin"   # PLUGIN_DIR as shell-quoted by plugin_bin()

binds=$(grep -c '^BIND|' <<<"$output" || true)
unbinds=$(grep -c '^UNBIND|' <<<"$output" || true)
(( binds == 31 )) || fail "31 bindings registered (30 workspace keys + former workspace)" "got $binds"
(( unbinds == 31 )) || fail "every registered binding is preceded by an unbind" "got $unbinds"
pass "31 bindings registered, each with a matching unbind"

# Every BIND must be directly preceded by an UNBIND of the same key.
prev=""
while IFS= read -r line; do
  case "$line" in
    UNBIND\|*) prev="${line#UNBIND|}" ;;
    BIND\|*)
      key=${line#BIND|}; key=${key%%|*}
      [[ "$key" == "$prev" ]] || fail "unbind precedes bind for $key" "previous unbind: $prev"
      prev=""
      ;;
  esac
done <<<"$output"
pass "each bind is preceded by an unbind of the same key"

for slot in 1 5 10; do
  code=$(( slot + 9 ))
  grep -qF "BIND|SUPER + code:$code|exec:$q/omarchy-switch-to-aw' $slot|" <<<"$output" ||
    fail "SUPER+$slot switches via omarchy-switch-to-aw" "$(grep "SUPER + code:$code|" <<<"$output")"
  grep -qF "BIND|SUPER + SHIFT + code:$code|exec:$q/omarchy-move-window-to-aw' $slot|" <<<"$output" ||
    fail "SUPER+SHIFT+$slot moves via omarchy-move-window-to-aw" "$output"
  grep -qF "BIND|SUPER + SHIFT + ALT + code:$code|exec:$q/omarchy-move-window-to-aw' --silent $slot|" <<<"$output" ||
    fail "SUPER+SHIFT+ALT+$slot passes --silent" "$output"
done
pass "slots 1, 5 and 10 route to the plugin wrappers (switch, move, silent move)"

grep -qF "BIND|SUPER + CTRL + TAB|focus:previous_per_monitor|" <<<"$output" ||
  fail "SUPER+CTRL+TAB uses previous_per_monitor" "$output"
pass "former-workspace binding uses previous_per_monitor"

# An uninstalled template (placeholder left in place) falls back to PATH lookups.
fallback=$(GWS_TEMPLATE="$ROOT/hypr/workspace-global.lua" HYPRLAND_INSTANCE_SIGNATURE=test HOME=/nonexistent lua << 'LUA'
local f = assert(io.open(os.getenv("GWS_TEMPLATE")))
local src = f:read("*a"); f:close()
local noop = function() end
hl = { get_monitors = function() return {} end, workspace_rule = noop, on = noop, unbind = noop,
  bind = function(keys, action) if keys == "SUPER + code:10" then print(action) end end,
  dsp = { exec_cmd = function(c) return c end, focus = function() return "" end } }
os.execute = noop
io.open = function() return nil end
assert(load(src))()
LUA
)
[[ "$fallback" == "omarchy-switch-to-aw 1" ]] ||
  fail "uninstalled template falls back to PATH lookups" "got: $fallback"
pass "uninstalled template falls back to bare command names"

# Outside a Hyprland session the file must register nothing (menu stub safety).
quiet=$(env -u HYPRLAND_INSTANCE_SIGNATURE GWS_TEMPLATE="$ROOT/hypr/workspace-global.lua" lua << 'LUA'
local f = assert(io.open(os.getenv("GWS_TEMPLATE")))
local src = f:read("*a"); f:close()
hl = setmetatable({}, { __index = function() error("hl touched outside Hyprland") end })
assert(load(src))()
print("quiet")
LUA
)
[[ "$quiet" == "quiet" ]] || fail "no Hyprland calls outside a live session" "got: $quiet"
pass "no Hyprland calls outside a live session"

# ── 2. End-to-end routing ─────────────────────────────────────────────────────
# Verify that omarchy-switch-to-aw and omarchy-move-window-to-aw (the targets
# of the new bindings) correctly route to the global helper when the flag is set
# and fall back to hyprctl when it is not.

FAKE_BIN=$(mktemp -d)
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN" "$STATE_DIR"' EXIT

GLOBAL_FLAG="$STATE_DIR/.local/state/omarchy/toggles/hypr/workspace-global.lua"
export HOME="$STATE_DIR"
export XDG_STATE_HOME="$STATE_DIR/.local/state"  # bin scripts honor XDG_STATE_HOME over $HOME

# Stub the global helpers so we can observe routing without a compositor.
cat > "$FAKE_BIN/omarchy-hyprland-workspace-global-switch" << 'STUB'
#!/bin/bash
echo "global-switch $*"
STUB
chmod +x "$FAKE_BIN/omarchy-hyprland-workspace-global-switch"

cat > "$FAKE_BIN/omarchy-hyprland-workspace-global-move-window" << 'STUB'
#!/bin/bash
echo "global-move $*"
STUB
chmod +x "$FAKE_BIN/omarchy-hyprland-workspace-global-move-window"

cat > "$FAKE_BIN/hyprctl" << 'STUB'
#!/bin/bash
echo "hyprctl $*"
STUB
chmod +x "$FAKE_BIN/hyprctl"

export PATH="$FAKE_BIN:$ROOT/bin:$PATH"

# Global mode: switch routes to omarchy-hyprland-workspace-global-switch.
mkdir -p "$(dirname "$GLOBAL_FLAG")" && touch "$GLOBAL_FLAG"

output=$("$ROOT/bin/omarchy-switch-to-aw" 5 2>/dev/null)
[[ "$output" == "global-switch 5" ]] ||
  fail "global mode: SUPER+5 routes to global switch helper" "got: $output"
pass "global mode: omarchy-switch-to-aw routes to global switch helper"

# Global mode: move routes to omarchy-hyprland-workspace-global-move-window.
output=$("$ROOT/bin/omarchy-move-window-to-aw" 5 2>/dev/null)
[[ "$output" == "global-move 5" ]] ||
  fail "global mode: SUPER+SHIFT+5 routes to global move helper" "got: $output"
pass "global mode: omarchy-move-window-to-aw routes to global move helper"

# Local mode: switch falls back to hyprctl.
rm "$GLOBAL_FLAG"
output=$("$ROOT/bin/omarchy-switch-to-aw" 5 2>/dev/null)
[[ "$output" == *"hyprctl"* && "$output" != *"global-switch"* ]] ||
  fail "local mode: SUPER+5 falls back to hyprctl" "got: $output"
pass "local mode: omarchy-switch-to-aw falls back to hyprctl"

# Local mode: move falls back to hyprctl.
output=$("$ROOT/bin/omarchy-move-window-to-aw" 5 2>/dev/null)
[[ "$output" == *"hyprctl"* && "$output" != *"global-move"* ]] ||
  fail "local mode: SUPER+SHIFT+5 falls back to hyprctl" "got: $output"
pass "local mode: omarchy-move-window-to-aw falls back to hyprctl"

# Local mode: follow move (no --silent) must NOT include follow=false.
# In Hyprland 0.56.2, moveToWorkspace without follow=false switches to the
# target workspace alongside the window. With follow=false it stays silent.
output=$("$ROOT/bin/omarchy-move-window-to-aw" 5 2>/dev/null)
[[ "$output" != *"follow = false"* ]] ||
  fail "local mode follow: SUPER+SHIFT+5 must NOT pass follow=false" "got: $output"
pass "local mode: follow move (no --silent) omits follow=false — window and display move together"

# Local mode: silent move (--silent flag) MUST include follow=false.
output=$("$ROOT/bin/omarchy-move-window-to-aw" --silent 5 2>/dev/null)
[[ "$output" == *"follow = false"* ]] ||
  fail "local mode silent: SUPER+SHIFT+ALT+5 must pass follow=false" "got: $output"
pass "local mode: silent move (--silent) passes follow=false — window moves, display stays"
