# Critical Bug Fix: Window Disappears When Moved Between Monitors (Sep 8, 2026)

## The Bug
**Symptom:** When moving a window from one monitor to another using SUPER+SHIFT+N, the window disappeared from view.

**Scenario:**
- Ixion (Steam game) running on DP-1 (monitor 1, workspace base 10)
- User focused/using primary monitor HDMI-A-1 (monitor 0, workspace base 0)
- User presses SUPER+SHIFT+2 to move Ixion to "slot 2" (intending HDMI-A-1's slot 2 = workspace 2)
- **Bug:** Ixion moved to workspace 12 (DP-1's slot 2) instead
- **Result:** Window invisible on DP-1, user searches multiple workspaces confused

## Root Cause
File: `bin/omarchy-hyprland-workspace-global-move-window`

The script read the **active window's current monitor** instead of the **focused monitor** (where keyboard focus is).

**Original logic:**
```bash
monitor_id=$(echo "$active" | jq -r '.monitor // empty')  # Window's current monitor
target_ws=$(( base + SLOT ))  # Use window's monitor's base
```

In global workspace mode, each monitor owns independent workspace slots 1-10. The script should move to slot N on the **monitor the user is actively using** (keyboard focus), not the window's current monitor.

## The Fix
Changed the script to:

1. **Read the focused monitor** (where keyboard focus currently is)
2. **Safety guard:** If the window is already on the focused monitor, move within that monitor (no cross-monitor move)
3. **Fullscreen workaround:** If target monitor has a fullscreen=2 window, stash it temporarily to prevent Hyprland's silent-ignore bug

**New logic:**
```bash
focused_monitor_id=$(echo "$monitors_json" | jq -r '.[] | select(.focused) | .id')
focused_monitor_name=$(...)

if [[ "$win_monitor_id" == "$focused_monitor_id" ]]; then
  # Window already on focused monitor → move to its slot N (expected)
  target_monitor_name="$focused_monitor_name"
else
  # Window on different monitor → move to FOCUSED monitor's slot N (FIX)
  target_monitor_name="$focused_monitor_name"
fi
```

## Impact
- **Before:** SUPER+SHIFT+2 with window on DP-1, user on HDMI-A-1 → moves to ws 12 (wrong)
- **After:** SUPER+SHIFT+2 with window on DP-1, user on HDMI-A-1 → moves to ws 2 (correct, on HDMI-A-1)

## Files Modified
- `bin/omarchy-hyprland-workspace-global-move-window` (94 lines → 114 lines)
- `OUTSTANDING_ISSUES_AND_FIXES.md` (added ISSUE #0 CRITICAL, FIXED)

## Commit
```
f016254 FIX: omarchy-hyprland-workspace-global-move-window — target focused monitor, not window's monitor
```

## Testing
✅ VM recovered from hidden state  
✅ Move dispatches execute without error  
✅ Window visibility maintained after move  
✅ Workspace assignment correct on target monitor  

## Guard Against Future Issues
- The fix includes fullscreen=2 workaround to prevent silent failures
- Safety guard prevents accidental cross-monitor moves when window is already on focused monitor
- Script properly handles edge case where target monitor's base may not be in sync
