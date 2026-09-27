# CRITICAL BUG FIX: Focus Stealing Breaks Global Workspace Switches (Sep 8, 2026)

**Commit:** `c3d357e`

## The Bug

When switching between global workspaces (e.g., AW1 ↔ AW2), **DP-1 (the monitor you were focused on) would get stuck viewing the WRONG workspace**. For example:

- You're on AW1 (DP-1 viewing ws=11)
- Press SUPER+2 → Ixion moves to AW2 (DP-1 viewing ws=12) ✓
- Press SUPER+1 → **DP-1 STAYS on ws=12, doesn't switch to ws=11** ✗
- Meanwhile, Signal/Teams/WhatsApp (on ws=11) become invisible
- Ixion (on ws=12) remains incorrectly visible

**Why:** The workspace switch dispatch silently failed. Hyprland received the dispatch command but ignored it due to corrupted internal state.

---

## Root Cause: Focus Stealing

**The script's processing order:**
1. Non-focused monitors first (HDMI-A-1, DP-2)
2. Originally-focused monitor last (DP-1)

**The bug in the old code:**

```bash
# For EVERY monitor, including non-focused ones:
hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = '$mon_name' }))"  # ← STEALS FOCUS!
hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"
```

**What happened:**
1. Process HDMI-A-1 (not focused): `focus({monitor: HDMI-A-1})` **steals focus away from DP-1**
2. Process DP-2 (not focused): `focus({monitor: DP-2})` **steals focus away from HDMI-A-1**
3. Process DP-1 (originally focused): `focus({monitor: DP-1})` **steals focus back to DP-1**
4. DP-1's `focus({workspace: 11})` tries to execute, but **Hyprland's internal state is corrupted** from all the focus thrashing
5. Workspace switch silently fails — DP-1 stays on ws=12

---

## The Fix

**Only the originally-focused monitor calls `focus({ monitor })`.**

Non-focused monitors only call `focus({ workspace })` to update their visible content. Hyprland correctly renders the workspace even without keyboard focus on that monitor.

**New code:**
```bash
if [[ "$is_focused" == "true" ]]; then
  # Originally-focused monitor: RESTORE focus after workspace changes
  hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = '$mon_name' }))"
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"
else
  # Non-focused monitor: UPDATE VISIBILITY without stealing focus
  hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = '$ws' }))"
fi
```

**Result:**
- Non-focused monitors: workspace.move() + focus({workspace}) only
- Originally-focused monitor: workspace.move() + focus({monitor}) + focus({workspace})

This keeps focus state consistent throughout the switch.

---

## Files Modified

- `bin/omarchy-hyprland-workspace-global-switch`
  - Added `is_focused` parameter to `switch_monitor()` function
  - Conditional focus handling: only focused monitor calls `focus({ monitor })`
  - Comprehensive comments explaining the bug and fix

---

## Verification

**Before fix:**
```bash
BEFORE: DP-1 viewing ws=12 (AW2)
Running: omarchy-hyprland-workspace-global-switch 1
AFTER: DP-1 viewing ws=12 (STUCK — should be 11)
```

**After fix:**
```bash
BEFORE: DP-1 viewing ws=12 (AW2)
Running: omarchy-hyprland-workspace-global-switch 1
AFTER: DP-1 viewing ws=11 (CORRECT ✓)
```

---

## Why This Wasn't Caught Before

The original code happened to work for many users because:
1. Single-monitor systems never trigger this (only one monitor, always focused)
2. Many Hyprland users switch workspaces via `moveworkspacetomon` which works differently
3. The bug only manifests when:
   - Multiple monitors with global workspaces
   - Non-focused monitor switches happen before the focused monitor
   - The workspace assignment + focus state gets corrupted

Your setup (3 monitors with global workspaces, rapid AW switching) exposed the bug reliably.

---

## Related Issues

- **Previous investigation (Sep 8):** Incorrectly blamed orphaned windows and added migration logic. While not wrong, that wasn't the root cause.
- **Real cause:** Focus state management, not window physical location.

---

## Testing

1. Verify Ixion switches between AW slots correctly
2. Verify Signal/Teams/WhatsApp remain visible on their AW
3. Rapid AW switching (SUPER+1, SUPER+2, SUPER+3, repeat) should be smooth
4. All three monitors should sync to the same AW slot

All verified ✓
