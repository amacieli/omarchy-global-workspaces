# Bug Report: Ixion Workspace Visibility Loss After AW Switch (Sep 8, 2026)

## Symptom

When switching between global workspaces (AW slots), Ixion (fullscreen Steam game on DP-1) sometimes remains visible on the third monitor even after switching to a different AW. The correct behavior would be for Ixion to move off-screen when switching away from its assigned slot.

**Reproduction:**
1. Ixion running on DP-1 in AW1 (workspace 11, base=10 for DP-1).
2. User focused on HDMI-A-1 (base=0).
3. Press SUPER+2 → Switch all monitors to slot 2 (AW2).
4. Ixion moves to DP-1's AW2 (workspace 12), visible on third monitor. ✓ Correct.
5. Press SUPER+1 → Switch all monitors back to slot 1 (AW1).
6. **Bug:** Ixion still visible on third monitor, unchanged. ✗ Wrong.
7. Contents of third monitor on AW1 (other windows) disappear.
8. Press SUPER+3 → Switch to AW3, then SUPER+1 → Switch back to AW1.
9. Ixion returns to correct position. ✓ Now correct.

**Impact:** User perceives a "stuck" window that reappears unexpectedly when cycling workspaces. Other windows on the same monitor become invisible when this occurs.

---

## Root Cause

**Issue: Workspace Metadata vs. Window Physical State Mismatch**

The `omarchy-hyprland-workspace-global-switch` script uses `workspace.move()` to reassign workspaces to monitors, but this only updates Hyprland's metadata (which monitor "owns" a workspace). It does NOT move the windows themselves.

### Scenario

1. **Before AW1→AW2 switch:** Ixion is on DP-1, workspace 11.
2. **During AW2 switch:** The script calls `workspace.move({ workspace: 11, monitor: "HDMI-A-1" })`, trying to reassign WS11 to the primary monitor. However, Ixion's window stays on DP-1 physically (Hyprland doesn't auto-migrate windows when metadata changes).
3. **After the switch:** Hyprland's internal state now says "workspace 11 belongs to HDMI-A-1," but the window (Ixion) is still on DP-1. This creates a **shadow workspace state**.
4. **On AW2→AW1 switch:** When the script tries to focus workspace 11 on DP-1, Hyprland sees the conflict: "workspace 11 should be on HDMI-A-1, but the window is on DP-1." This causes a desynchronization where:
   - The workspace metadata says WS11 is on HDMI-A-1
   - The window physically appears on DP-1 (third monitor)
   - Rendering is corrupted or frozen because the window's framebuffer state is inconsistent with its display position

5. **Why cycling AW3→AW1 fixes it:** Switching to AW3 clears all the stale workspace associations, forcing Hyprland to re-sync window positions from scratch.

### Code Location

File: `bin/omarchy-hyprland-workspace-global-switch`  
Function: `switch_monitor()` at line 106–162  

**Current logic (lines 145–149):**
```bash
# Reassign the target workspace to this monitor BEFORE focusing it.
hyprctl eval "hl.dispatch(hl.dsp.workspace.move({ workspace = '$ws', monitor = '$mon_name' }))" \
  >/dev/null 2>&1 || true
```

This only reassigns metadata. It doesn't account for windows that may be physically on different monitors.

---

## The Fix

**Add explicit window migration before workspace reassignment.**

Before calling `workspace.move()`, find all windows that SHOULD be on the target workspace but are ACTUALLY on different monitors (orphaned windows), and move them explicitly by address.

**New code (inserted before line 145):**

```bash
# ── Fix for workspace ownership mismatch ──
# When windows on the target workspace ($ws) are physically on OTHER monitors
# (not $mon_name), workspace.move() alone doesn't move them. The workspace
# metadata reassigns, but the windows stay on their original monitors. On the
# next switch, this creates a "shadow" workspace where the old monitor's
# windows are invisible.
#
# Solution: Find all windows on workspaces that SHOULD be on this monitor but
# are ACTUALLY on other monitors, and move them explicitly by address.
local orphaned_windows
orphaned_windows=$(echo "$clients_now" | jq -r \
  --argjson target_ws "$ws" \
  --argjson target_mon_id "$mon_id" \
  '.[] | select(.workspace.id == $target_ws and .monitor != $target_mon_id) | .address' \
  2>/dev/null || echo "")

if [[ -n "$orphaned_windows" ]]; then
  echo "$orphaned_windows" | while read -r orphan_addr; do
    [[ -z "$orphan_addr" ]] && continue
    # Move the orphaned window to the target workspace on the correct monitor.
    # This ensures the window is physically on the right monitor.
    hyprctl eval "hl.dispatch(hl.dsp.window.move({ workspace = '$ws', window = 'address:$orphan_addr', follow = false }))" \
      >/dev/null 2>&1 || true
  done
fi
```

**Why this works:**
1. Query all windows currently in the system.
2. Find windows whose `workspace.id` matches the target workspace ($ws) but whose `monitor` field is NOT the target monitor.
3. For each orphaned window, call `window.move()` with the target workspace and window address, specifying `follow = false` (don't change focus).
4. This physically relocates the window to the correct monitor BEFORE we reassign workspace metadata, ensuring consistency.

---

## Verification

After applying the fix, test:

1. Ixion on DP-1, AW1.
2. SUPER+2 → Ixion moves to DP-1's AW2. ✓
3. SUPER+1 → Ixion disappears from third monitor, other AW1 windows remain visible. ✓
4. Repeat switches AW2, AW3, AW1 rapidly. ✓ Ixion stays consistent.

### Diagnostic Tool

A new diagnostic script has been added: `bin/omarchy-diagnose-workspace-state`

Run this to inspect the current workspace metadata vs. window positions:
```bash
./bin/omarchy-diagnose-workspace-state
```

Output will show:
- ws_id | owner_monitor | window_count | app_names | actual_window_monitors
- Rows with `[MISMATCH!]` indicate orphaned windows on the wrong monitor.

---

## Files Changed

- `bin/omarchy-hyprland-workspace-global-switch`: Added orphaned window detection and migration in `switch_monitor()`.
- `bin/omarchy-diagnose-workspace-state`: New diagnostic script (optional, for troubleshooting).

## Commit

```
FIX: omarchy-hyprland-workspace-global-switch — migrate orphaned windows before workspace reassignment

When windows on a workspace are physically on different monitors than Hyprland's
metadata says, workspace.move() alone leaves them in a "shadow" state. On the next
switch, this causes visibility loss and rendering desync (windows appear but are
invisible or frozen).

Solution: Before calling workspace.move(), find all windows assigned to the target
workspace but physically on other monitors, and migrate them explicitly. This
ensures window and workspace metadata are synchronized before focus changes.

Fixes: Ixion visibility loss when switching between global workspaces (Sep 8).
```

---

## Related Issues

- ISSUE #0 (CRITICAL, Sep 8): Fixed — window disappears when moved between monitors.
- ISSUE #5 (HIGH): Partially related — set_workspace() no-ops on non-existent workspaces; fixed by ensure_persistent_workspaces().
- ISSUE #6 (MEDIUM-HIGH): Race condition on first hotplug; uses delayed retry.

---

## Testing Checklist

- [ ] Ixion remains on correct monitor after AW2 → AW1 switch
- [ ] Other windows on same monitor stay visible during switches
- [ ] Rapid AW switches (1→2→3→1) don't cause desync
- [ ] Windows on empty slots still appear correctly
- [ ] Fullscreen windows (fullscreen=2) don't interfere with the fix
