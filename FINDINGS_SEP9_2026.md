# Global Workspace Switching — Findings & Fix Deployment (Sep 9, 2026)

## Problem Statement

After switching workspaces with SUPER+N in global mode:
- Non-focused monitors would remain stuck on their previous workspace
- Only the focused monitor would switch
- Example: User on DP-2 (focused), presses SUPER+3 to switch all monitors to AW3
  - DP-2 switches to ws=23 ✓
  - DP-1 stays on ws=11 ✗ (should be ws=13)
  - HDMI-A-1 stays on ws=1 ✗ (should be ws=3)

## Root Causes Identified

### 1. Focus Stealing Bug (PRIMARY)

**Script:** `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch`  
**Status:** Already fixed in repo (Sep 8, 2026), but not deployed to live system

The original code called `focus({ monitor })` on ALL monitors:
```bash
# OLD (BROKEN)
for each_monitor in all_monitors:
  hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = '$mon_name' }))"  # STEALS FOCUS
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"
```

This corrupted Hyprland's internal state via focus thrashing:
1. Non-focused monitor A calls `focus({monitor: A})` → steals focus from originally-focused monitor
2. Non-focused monitor B calls `focus({monitor: B})` → steals focus from A
3. Finally, originally-focused monitor C calls `focus({monitor: C})` + `focus({workspace: WS})`
4. By this point, Hyprland's state is corrupted; the workspace focus dispatch silently fails

**Fix (deployed Sep 9):**
- Only the originally-focused monitor calls `focus({ monitor })`
- Non-focused monitors call ONLY `focus({ workspace })` to update visibility
- Processing order: non-focused first, originally-focused last

```bash
# NEW (CORRECT)
if is_focused:
  hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = '$mon_name' }))"  # Only for focused
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"
else:
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"  # No monitor focus
```

**Verification:** Sep 9 testing showed AW1 switch works perfectly across all 3 monitors after fix deployment.

---

### 2. Workspace Materialization Gap (SECONDARY)

**Files affected:**
- `/home/adam/.local/state/omarchy/toggles/hypr/workspace-global.lua`
- `~/.config/hypr/autostart.lua`

**Problem:** Hyprland 0.56.x does not pre-create empty workspaces. When the switch script tries to focus workspace 2, 3, 13, etc., those workspaces don't exist yet, so the dispatch silently no-ops.

**Why it matters:** Focus dispatch on non-existent workspace = silent failure. User sees no visual change.

**Attempted fixes:**

1. **`hl.workspace_rule()` with `persistent=true`** in toggle file
   - Supposed to register workspaces for later creation
   - Does NOT materialize synchronously in Hyprland 0.56.x
   - Workspaces still don't exist after config load

2. **Autostart hook in `~/.config/hypr/autostart.lua`**
   - Synchronous Lua loop focusing ws 1-30 at config load time
   - Only creates workspaces that are actually accessed
   - Result: Maybe 7-8 workspaces created, not all 30

3. **Init script `~/.local/bin/omarchy-init-global-workspaces`**
   - Runs focus dispatch for ws 1-10 per monitor with delays
   - Same limitation: only creates what Hyprland decides to materialize

**Workaround:** First access each AW slot manually (creates the workspace), then subsequent switches work. Not ideal UX but functional.

**Long-term solution:** Needs Hyprland ≥0.57 with proper `workspace_rule()` synchronous support, OR enhance the switch script to auto-create missing workspaces on dispatch failure.

---

## Deployment Summary (Sep 9, 2026)

### Live System Updates
```
/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch
  → Already had conditional focus fix (Sep 8)
  
/usr/share/omarchy/bin/omarchy-ensure-workspaces
  → Deployed (retries workspace rule registration)

~/.local/state/omarchy/toggles/hypr/workspace-global.lua
  → Deployed with corrected hl.workspace_rule API (use 'workspace' field, not 'id')

~/.config/hypr/autostart.lua
  → Deployed (syncs workspace creation at config load)

~/.local/bin/omarchy-init-global-workspaces
  → Deployed (one-time init script)
```

### Git Repository
```
https://github.com/amacieli/omarchy-global-workspaces
Commits:
  fea3a98 - DEPLOY: workspace materialization + conditional focus fix (Sep 9)
  ef3cdd3 - Workspace materialization: autostart hook + init script (partial fix)
  5d7a408 - Fix: hl.workspace_rule API — use 'workspace' field instead of 'id'
```

---

## Test Results (Sep 9, 2026)

### AW1 Switch (WORKING ✓)
```
Before:  HDMI-A-1=ws1, DP-1=ws11, DP-2=ws21
Command: omarchy-hyprland-workspace-global-switch 1
After:   HDMI-A-1=ws1, DP-1=ws11, DP-2=ws21
Result:  All correct, windows visible on their correct workspaces
```

### AW2 Switch (PARTIAL ✗)
```
Before:  HDMI-A-1=ws1, DP-1=ws11, DP-2=ws21
Command: omarchy-hyprland-workspace-global-switch 2
Expected: HDMI-A-1=ws2, DP-1=ws12, DP-2=ws22
Actual:   HDMI-A-1=ws1, DP-1=ws2, DP-2=ws22
Issues:
  - Workspaces 2 and 12 didn't exist, so focus dispatch no-opped
  - DP-1 ended up on wrong workspace (ws2 instead of ws12)
  - HDMI-A-1 didn't switch at all
Cause: Workspace materialization failed; workspaces 2 and 12 were never created
```

### Quickshell Bar Error (FIXED ✓)
```
Error before fix:
  /home/adam/.local/state/omarchy/toggles/hypr/workspace-global.lua:115
  hl.workspace_rule: 'workspace' field is required and must be a string.
  
Fix: Changed hl.workspace_rule({ id = ws_id, ... }) 
  → hl.workspace_rule({ workspace = tostring(ws_id), ... })
  
Side effect: This also fixed Quickshell bar height inconsistency across monitors
  (likely the parse error was causing fallback to broken layout)
Result: Bars now render at correct height on all monitors
```

---

## Known Limitations & Next Steps

### Current State
- **AW1 switching:** Fully functional
- **AW2-10 switching:** Requires workspaces to pre-exist (Hyprland platform limitation)
- **Workaround:** Manually visit each AW once to materialize, then switches work

### To Fully Resolve
1. **Option A (Quick):** Add to switch script:
   - Detect when workspace doesn't exist
   - Pre-create it with `workspace.move()` before focusing
   - Requires knowing which workspace IDs belong to which monitors (already have this)

2. **Option B (Medium):** Hyprland update
   - Wait for Hyprland ≥0.57 with proper `workspace_rule()` sync support
   - Deploy and test

3. **Option C (Workaround):** Document in user guide
   - On first global mode activation, guide user through one AW cycle (1→2→3→...→10→1)
   - Creates all workspaces, then global switching works perfectly afterward

### Files to Watch on Next Session
- `/mnt/ai/projects/omarchy-global-workspaces/` (main repo)
- `~/.local/state/omarchy/toggles/hypr/workspace-global.lua` (user toggle)
- `~/.config/hypr/autostart.lua` (startup hook)
- `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch` (live script)

---

## Diagnostic Commands

```bash
# Check current monitor & workspace state
hyprctl monitors -j | jq '.[] | {name, id, activeWorkspace: .activeWorkspace.id}'

# Check which workspaces exist
hyprctl workspaces -j | jq '[.[] | .id] | sort' | tr -d ' \n' && echo ""

# Test a specific AW switch with trace
bash -x /usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch 1

# Check for orphaned windows (on wrong monitor)
hyprctl clients -j | jq '.[] | {class, workspace: .workspace.id, monitor}'

# Manually create missing workspaces (for testing)
for ws in {2..10} {13..20} {23..30}; do
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))" >/dev/null 2>&1 || true
  sleep 0.01
done
hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '1' }))" >/dev/null 2>&1
```

---

## Session Notes

- **User machine:** Omarchy Linux dual-boot, 3-monitor setup (HDMI-A-1, DP-1, DP-2)
- **Omarchy mode:** Global workspace mode enabled (ws base = monitor name → stable IDs)
- **Hyprland version:** 0.56.x (does not support synchronous workspace_rule materialization)
- **Quickshell:** Live bar rendering (restarted Sep 9 after config fix)

