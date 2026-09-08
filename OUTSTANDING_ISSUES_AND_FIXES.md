# Outstanding Issues from PR #10199 Review

**Status:** 5/10 comments addressed. 5 still open.

---

## ISSUE #0 (CRITICAL, Sep 8, 2026): Window Disappears When Moved Between Monitors

**Severity:** CRITICAL (user-impacting window visibility loss)  
**Status:** ✅ FIXED

### Finding
User: Ixion (Steam game) running on DP-1 (base=10). User focused on HDMI-A-1 (base=0).  
Action: SUPER+SHIFT+2 to move Ixion to AW#2 (intending primary monitor's slot 2).  
Bug: Window moved to workspace 10+2=12 (DP-1's slot 2, invisible to user).  
Effect: Window disappeared from view; user had to search multiple workspaces to find it.

**Root cause:** Script read the active window's **current monitor** instead of **focused monitor** (keyboard focus). In global mode, SUPER+SHIFT+N should move to slot N on the monitor the user is actively using, not the window's monitor.

### Fix Applied (Sep 8, 2026)
File: `bin/omarchy-hyprland-workspace-global-move-window`  
**Change:** Target the focused monitor (keyboard focus) instead of window's current monitor.

**Guard:** If the active window is already on the focused monitor, stay on same monitor (no cross-monitor move). Prevents accidental cross-monitor relocations.

**Fullscreen workaround included:** If target monitor has a fullscreen=2 window, stash it temporarily (workspace 999), move the window, restore the fullscreen window. Prevents Hyprland's silent-ignore bug on fullscreen monitors.

### Test Case
- Window: Ixion on DP-1 (monitor 1)
- User focus: HDMI-A-1 (monitor 0, base=0)
- Action: SUPER+SHIFT+2
- Expected: Ixion moves to workspace 2 (HDMI-A-1's slot 2), visible on primary monitor
- Result: ✅ Ixion now correctly visible on HDMI-A-1, slot 2

---

## ISSUE #2: QML Offset Formula Duplication (isaac30503, Sep 5)

**Severity:** LOW (design optimization)  
**Status:** ⚠ OPEN

### Finding
isaac30503 points out that the QML side doesn't need to duplicate the offset formula. Quickshell already exposes:
- `Hyprland.monitorFor(screen)` → this bar's monitor
- `HyprlandWorkspace.monitor` → which monitor owns a workspace
- `HyprlandMonitor.activeWorkspace` → that monitor's own active WS

Deriving each bar's slot from `Hyprland.workspaces.values` filtered by `w.monitor.id === myMonitor.id` is agnostic to whatever base scheme the Lua side picks. QML doesn't need to import or duplicate the offset formula.

### Current Code
`Workspaces.qml` lines 81–106: loads `monitor-bases.json` into QML directly and duplicates the `ws.id - base` formula in `awIsOccupied()` (line 189).

### Recommended Fix
This is a design decision with tradeoffs:
- **Current design (monitor-bases in QML):** Tight coupling; QML knows the formula and reads the map directly.
- **Suggested design (formula in Lua only):** Cleaner separation; QML just queries "is WS X on this monitor?" and Lua handles bases.

**For now:** Document as a follow-up optimization, not a critical fix. The current approach works and is explicit. If Lua-side base changes become frequent, refactor QML to query through an IPC interface instead.

**Action:** Document in PR as "resolved by design" — no code change needed for this PR, but noted for future decoupling.

---

## ISSUE #4: HLMonitor:set_workspace() Ignores warp_on_change_workspace (isaac30503, Sep 7)

**Severity:** MEDIUM (cursor warping broken)  
**Status:** ⚠ OPEN

### Finding
isaac30503 verified against Hyprland 0.56.2 source (`src/config/lua/objects/LuaMonitor.cpp`):
- `HLMonitor:set_workspace(id)` calls `changeWorkspace(id)` directly with `noMouseMove=false` but NEVER reads `cursor:warp_on_change_workspace`.
- Only `CA::changeWorkspace()` (used by `hl.dsp.focus({workspace=...})`) reads the warp option.
- A synchronized switch built on `set_workspace()` never warps the pointer, even with `warp_on_change_workspace = 1` set (Omarchy's default).

### Impact
If a user has `warp_on_change_workspace = 1` configured, switching workspaces doesn't move the cursor to the new focus point. Keyboard focus follows, but the pointer stays behind, breaking expected behavior.

### Current Code
`omarchy-hyprland-workspace-global-switch` uses `hl.dsp.focus({workspace = '...'})` and `hl.dsp.focus({monitor = '...'})` (lines 145–148), which DO respect the warp option.

**Workaround in current code:** Processing order is highest-base monitors first, originally-focused monitor last (lines 157–170). This ensures the originally-focused monitor's keyboard focus is set LAST, preventing the "focus jumps back" effect. However, the pointer warp still only happens on the LAST `hl.dsp.focus()` call (the focused monitor), not all of them.

### Recommended Fix
**The current code is already using `hl.dsp.focus()`, which respects the warp option.** However, the pointer only warps on the LAST monitor (the focused one). If you want pointer warps on ALL monitors:

1. **Option A (Conservative):** Document the behavior — pointer warps to the focused monitor, not to intermediate monitors. This is correct UX (cursor stays with focus).

2. **Option B (Explicit):** After all monitors are switched, explicitly warp to the focused monitor's active window:
   ```bash
   # After the switch_monitor loop, get the focused window's position
   focused_win=$(hyprctl activewindow -j | jq -r '.at | @csv')
   # Cursor is already where it should be if hl.dsp.focus() warped correctly
   ```

**Action for this PR:** No code change needed. The `hl.dsp.focus()` path respects warp_on_change_workspace. Document in a comment that warp only applies to the focused monitor's final switch.

---

## ISSUE #5: set_workspace() Silently No-ops on Non-existent Workspaces (isaac30503, Sep 7)

**Severity:** HIGH (silent failure, empty slot switching doesn't work)  
**Status:** ⚠ OPEN

### Finding
isaac30503 verified against Hyprland 0.56.2 source (`src/config/lua/objects/LuaMonitor.cpp`):
```cpp
int LuaMonitor::set_workspace(lua_State* L) {
  // ...
  if (!ws) return 0;  // <-- silent no-op if workspace doesn't exist
}
```

When you try to switch a monitor to a workspace it has never visited (slot N on a monitor that hasn't materialized WS(base+N) yet), the dispatch silently fails with no error.

### Impact
First time switching to an empty slot on a newly-connected monitor just does nothing. The user presses SUPER+1 but nothing happens.

### Current Code
`omarchy-hyprland-workspace-global-switch` relies on workspaces existing before `hl.dsp.focus()` is called. If a monitor has never visited slot 1, WS(base+1) may not exist.

### Recommended Fix
Materialize all workspace slots ahead of time using `hl.workspace_rule()` with `persistent = true`:

```lua
-- In workspace-global.lua or tiling.lua, after the toggle is active:
local function ensure_persistent_workspaces()
  for i = 1, #_G.omarchy_global_ws_monitors do
    local mon = _G.omarchy_global_ws_monitors[i]
    local base = mon.base
    -- For each slot 1-10, register a persistent rule for this monitor's range
    for slot = 1, 10 do
      local ws_id = base + slot
      hl.workspace_rule({
        id = ws_id,
        monitor = mon.name,
        persistent = true,  -- <-- keeps it alive even if empty
        -- optionally: default = { layout = "master" }
      })
    end
  end
end

-- Call once at startup (or onload in the toggle)
if hl.workspace_rule then
  ensure_persistent_workspaces()
end
```

**Placement:** Add to `workspace-global.lua` after the monitor list is built (around line 92).

**Action for this PR:** Patch `hypr/toggles/workspace-global.lua` to add workspace_rule() calls.

---

## ISSUE #6: hl.workspace_rule() Materialization Race (isaac30503, Sep 7)

**Severity:** MEDIUM-HIGH (race condition on first hotplug)  
**Status:** ⚠ OPEN

### Finding
isaac30503 tested: `hl.workspace_rule()` doesn't materialize synchronously within the same script tick. Calling `hl.get_workspace(id)` immediately after registering a rule can still return nil, especially on fresh identities.

### Impact
If you try to auto-park a newly-connected monitor to its first slot immediately after registering workspace rules for it, the `hl.get_workspace()` check fails, and the workspace doesn't exist yet. Timing-dependent bug.

### Current Code
`workspace-global.lua` calls `omarchy-monitor-base sync` and builds the base map (lines 50–68), then calls `hl.get_monitors()` and sorts (lines 73–81). No `hl.get_workspace()` check or retry.

### Recommended Fix
Add a delayed retry mechanism:

```lua
-- After ensure_persistent_workspaces() above, schedule a retry:
local function verify_workspaces()
  for i = 1, #_G.omarchy_global_ws_monitors do
    local mon = _G.omarchy_global_ws_monitors[i]
    local base = mon.base
    -- Check if the first slot exists; if not, retry after 100ms
    local ws1_exists = hl.get_workspace(base + 1) ~= nil
    if not ws1_exists then
      -- Schedule a re-check via backgrounded hyprctl eval
      os.execute("sleep 0.1 && hyprctl eval 'hl.get_workspace(" .. (base + 1) .. ")' >/dev/null 2>&1 &")
    end
  end
end

-- After ensure_persistent_workspaces()
if hl.get_monitors then
  verify_workspaces()
end
```

**Better approach:** Use a bash wrapper script (call from workspace-global.lua):
```bash
# omarchy-ensure-workspaces (new script)
#!/bin/bash
BASES_JSON="$HOME/.local/state/omarchy/monitor-bases.json"
for mon_name in $(jq -r 'keys[]' "$BASES_JSON" 2>/dev/null); do
  for slot in 1 2 3 4 5; do
    ws_id=$(($(jq -r ".[\"$mon_name\"]" "$BASES_JSON") + slot))
    hyprctl eval "hl.workspace_rule({ id = $ws_id, monitor = '$mon_name', persistent = true })" >/dev/null 2>&1 || true
    sleep 0.05  # Small delay between rules
  done
done
sleep 0.1  # Give Hyprland time to create the workspaces
qs ipc call omarchy.workspaces refresh &  # Refresh bars after creation
```

Then call from `workspace-global.lua`:
```lua
os.execute("omarchy-ensure-workspaces &")
```

**Action for this PR:** 
1. Add `ensure_persistent_workspaces()` function to `hypr/toggles/workspace-global.lua`.
2. Create new script `bin/omarchy-ensure-workspaces` with the retry-and-delay logic.
3. Call from the toggle on startup.

---

## ISSUE #7: HYPRLAND_INSTANCE_SIGNATURE for Reboot Detection

**Severity:** LOW (optimization, already partially addressed)  
**Status:** ✓ MOSTLY COVERED

### Finding
isaac30503 suggests using `HYPRLAND_INSTANCE_SIGNATURE` as a cheap reboot detector:
- Set once per compositor process (stable across `hyprctl reload`)
- Changes on every real Hyprland start
- Use for: "reset persisted state cleanly on reboot (nothing has windows yet), but survive in-session reload"

### Current Code
`workspace-global.lua` lines 44–48 already guard `io.popen()` and `hl.get_monitors()` behind a `HYPRLAND_INSTANCE_SIGNATURE` check:
```lua
if not os.getenv("HYPRLAND_INSTANCE_SIGNATURE") then
  _G.omarchy_monitor_bases = {}
  _G.omarchy_global_ws_monitors = {}
  return
end
```

This prevents the script from running inside the keybindings menu stub. ✓

### Additional Recommendation
If you want to reset monitor base assignments cleanly on reboot:

```lua
-- Compare INSTANCE_SIGNATURE to persisted value
local function check_reboot()
  local current_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
  local sig_file = os.getenv("HOME") .. "/.local/state/omarchy/.hyprland-instance"
  local last_sig = ""
  
  local f = io.open(sig_file, "r")
  if f then
    last_sig = f:read("*a"):match("^%s*(.-)%s*$")
    f:close()
  end
  
  -- If signature changed, it's a real reboot; reset state
  if current_sig ~= last_sig then
    os.execute("rm -f " .. os.getenv("HOME") .. "/.local/state/omarchy/monitor-bases.json")
    -- Regenerate on next sync
  end
  
  -- Persist the current signature
  local f = io.open(sig_file, "w")
  if f then
    f:write(current_sig .. "\n")
    f:close()
  end
end

-- Call early in workspace-global.lua
check_reboot()
```

**Action for this PR:** Optional. The guard is already there. Add this reboot-detection function only if you want to reset bases on clean reboots.

---

## ISSUE #8: Recovering Windows Stranded by Disconnected Monitor (isaac30503, Sep 7)

**Severity:** HIGH (data loss without recovery)  
**Status:** ⚠ OPEN

### Finding
When an external monitor disconnects, windows on its workspaces become inaccessible. isaac30503 tested three approaches:

1. **Auto-migrate on disconnect** (hyprsplit's `grab_rogue_windows`): Dumps all orphaned windows onto whatever's left. BAD: every momentary cable disconnect reshuffles everything.

2. **Collapse to current monitor** (first attempt): Loses each window's logical slot info.

3. **Manual rescue + modular arithmetic** (what worked): User-triggered rescue that moves each stranded window back to its same SLOT on a guaranteed-present monitor (laptop panel). Formula: `(ws_id - 1) % slots + 1` gives the slot without needing the disappeared base.

### Current Code
No `monitor.removed` handler or stranded-window recovery in the codebase.

### Recommended Fix
Create a new rescue script `bin/omarchy-recover-stranded-windows`:

```bash
#!/bin/bash
# Recover windows stranded on disconnected-monitor workspaces.
# Moves each stranded window to the same LOGICAL SLOT (1-10) on an available monitor.
#
# Usage: omarchy-recover-stranded-windows
#
# Formula: slot = (ws_id - 1) % 10 + 1  (gives 1-10 from any ws_id)

set -euo pipefail

BASES_JSON="$HOME/.local/state/omarchy/monitor-bases.json"
if [[ ! -f "$BASES_JSON" ]]; then
  echo "monitor-bases.json not found" >&2
  exit 1
fi

# Map monitor name → base
declare -A bases
while IFS=' ' read -r mon_name mon_base; do
  [[ -n "$mon_name" ]] && bases["$mon_name"]="$mon_base"
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "$BASES_JSON")

# Get all monitors currently connected
declare -A current_mons
while IFS=' ' read -r mon_name; do
  current_mons["$mon_name"]=1
done < <(hyprctl monitors -j | jq -r '.[].name')

# Find an available "home" monitor (prefer laptop panel, fallback to first available)
home_mon=""
for mon_name in eDP-1 HDMI-1 DP-1 DP-2 DP-3; do
  if [[ -n "${current_mons[$mon_name]:-}" ]]; then
    home_mon="$mon_name"
    break
  fi
done

if [[ -z "$home_mon" ]]; then
  echo "No available monitors found" >&2
  exit 1
fi

home_base="${bases[$home_mon]:-0}"
echo "Rescuing stranded windows to monitor '$home_mon' (base=$home_base)"

# List all workspaces, find those on disconnected monitors
hyprctl workspaces -j | jq -r '.[] | "\(.id) \(.monitor.name)"' | while read -r ws_id mon_name; do
  # Skip if this monitor is still connected
  [[ -n "${current_mons[$mon_name]:-}" ]] && continue
  
  # Workspace is orphaned — move windows from it to the home monitor at same slot
  slot=$(( (ws_id - 1) % 10 + 1 ))
  target_ws=$(( home_base + slot ))
  
  echo "  Workspace $ws_id (on gone monitor '$mon_name') → moving windows to WS $target_ws (slot $slot on $home_mon)"
  
  # Get windows on the orphaned workspace
  hyprctl clients -j | jq -r ".[] | select(.workspace.id == $ws_id) | .address" | while read -r addr; do
    [[ -z "$addr" ]] && continue
    hyprctl eval "hl.dispatch(hl.dsp.window.move({ workspace = '$target_ws', window = 'address:$addr', follow = false }))" >/dev/null 2>&1 || true
  done
done

echo "Recovery complete. Switch to $home_mon to see recovered windows."
```

**Placement:** `bin/omarchy-recover-stranded-windows`

**Invocation:** Create a bar menu item or keybinding:
```bash
# In omarchy config or shell/menu:
"Recover stranded windows after monitor disconnect" → omarchy-recover-stranded-windows
```

**Alternative: Auto-recovery with monitor.removed handler**
If you want automatic recovery when a monitor actually disconnects (not just recovery on demand), Hyprland v0.57+ supports monitor lifecycle events. But implementing a `monitor.removed` handler is complex and may be overkill — the manual script is safer and doesn't risk reshuffling on transient disconnects.

**Action for this PR:** 
1. Create `bin/omarchy-recover-stranded-windows` script.
2. Document in README: "After unplugging an external monitor, run `omarchy-recover-stranded-windows` to recover windows."
3. Optional: add a keybinding or menu item for quick access.

---

## ISSUE: ipairs() Hang in hyprland.lua (isaac30503, Sep 5)

**Severity:** MEDIUM (menu hangs if not guarded)  
**Status:** ⚠ OPEN

### Finding
isaac30503 found that when `omarchy-menu-keybindings` evaluates `hyprland.lua` under a stub Lua environment, the stub's `__index` returns a truthy sentinel for every key. Any `ipairs()` call on a stub object loops forever (sees no nil, never terminates).

Related issue: [omacom/omarchy#7025](https://github.com/omacom/omarchy/issues/7025)

### Current Code
`hypr/toggles/workspace-global.lua` line 85 correctly uses numeric `for i = 1, #mons do` instead of `ipairs()`:
```lua
for i = 1, #monitors do
  local mon = monitors[i]
  -- ...
end
```

✓ Already correct.

### Recommendation
Ensure no other files in `hypr/` use `ipairs()` on Hyprland objects:
```bash
grep -r "ipairs" bin/ hypr/ shell/ 2>/dev/null | grep -v ".git" || echo "No ipairs() found"
```

**Action for this PR:** Audit existing files for `ipairs()` on monitors or Hyprland data. If none found, document the pattern in README.

---

## Summary of Patches Required

| Issue | Severity | File(s) | Action |
|-------|----------|---------|--------|
| #2: QML offset duplication | LOW | Workspaces.qml | Document as design choice; no code change. |
| #4: warp_on_change_workspace | MEDIUM | omarchy-hyprland-workspace-global-switch | Add comment; code already uses `hl.dsp.focus()` which respects warp. |
| #5: set_workspace() no-ops | HIGH | hypr/toggles/workspace-global.lua | Add `ensure_persistent_workspaces()` + new script `omarchy-ensure-workspaces`. |
| #6: workspace_rule() race | MEDIUM-HIGH | hypr/toggles/workspace-global.lua + new script | Add retry logic with delay; call from toggle. |
| #7: HYPRLAND_INSTANCE_SIGNATURE | LOW | hypr/toggles/workspace-global.lua | Optional: add reboot-detection function. |
| #8: stranded windows | HIGH | bin/omarchy-recover-stranded-windows (new) | Create recovery script with modular arithmetic. |
| ipairs() hang | MEDIUM | (audit only) | Verify no `ipairs()` on Hyprland objects; document pattern. |

---

## Recommended PR Update Strategy

1. **High-severity fixes (will do immediately):**
   - #5: Add workspace_rule() materialization to `workspace-global.lua`
   - #6: Add retry logic and new `omarchy-ensure-workspaces` script
   - #8: Create `omarchy-recover-stranded-windows` script

2. **Medium-severity (document + optional):**
   - #4: Add clarifying comment in switch script about warp behavior
   - ipairs(): Audit and document numeric-for pattern

3. **Low-severity (can defer):**
   - #2: Note in PR as "design resolved"; consider for future refactor
   - #7: Optional reboot-detection enhancement; document if added

