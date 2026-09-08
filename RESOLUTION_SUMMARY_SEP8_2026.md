# RESOLUTION SUMMARY: Ixion Workspace Visibility Bug (Sep 8, 2026)

## Status: ✅ FIXED AND TESTED

**Latest Commit:** `8f80aab`  
**GitHub:** https://github.com/amacieli/omarchy-global-workspaces

---

## What Was Wrong

When switching global workspaces (AW1 ↔ AW2), **the monitor you were focused on would get stuck viewing the wrong workspace**. The switch dispatch would silently fail.

**Your symptom:**
- Pressed SUPER+1 to switch to AW1
- DP-1 stayed stuck on AW2 (ws=12) instead of switching to AW1 (ws=11)
- Ixion (on ws=12) remained visible when it should be hidden
- Signal/Teams/WhatsApp (on ws=11) became invisible

---

## Why It Happened

**The root cause: FOCUS STEALING**

The original script called `focus({ monitor })` on ALL monitors during the switch, including non-focused ones. This thrashed the keyboard focus state:

1. Switch HDMI-A-1 (not focused) → `focus({monitor: HDMI-A-1})` steals focus from DP-1
2. Switch DP-2 (not focused) → `focus({monitor: DP-2})` steals focus from HDMI-A-1
3. Switch DP-1 (originally focused) → `focus({monitor: DP-1})` steals focus back
4. DP-1 tries `focus({workspace: 11})` → **Hyprland's state is corrupted, dispatch silently fails**
5. DP-1 stays stuck on ws=12

---

## The Fix

**Only the originally-focused monitor handles focus.**

Non-focused monitors update their workspace visibility without calling `focus({ monitor })`, which steals focus. This keeps Hyprland's internal state consistent.

**Changes to:** `bin/omarchy-hyprland-workspace-global-switch`

```bash
# Non-focused monitors:
workspace.move()           # Reassign workspace to monitor
focus({workspace})         # Update visible content (NO focus steal)

# Originally-focused monitor:
workspace.move()           # Reassign workspace to monitor
focus({monitor})           # Restore keyboard focus
focus({workspace})         # Final workspace focus
```

**Result:** All monitors sync correctly to the target AW slot, with focus remaining on the originally-focused monitor.

---

## Installation

The fix is already installed on your system:

```
/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch (UPDATED)
```

---

## Verification (PASSED ✓)

**Test sequence:**
1. DP-1 viewing AW2 (ws=12), Ixion on ws=12
2. Run: `omarchy-hyprland-workspace-global-switch 1`
3. **Result:** DP-1 now viewing AW1 (ws=11) ✓
4. **Ixion status:** Hidden (correctly on ws=12, which is not visible) ✓

**Your workflow verified:**
- Signal/Teams/WhatsApp on ws=11 (AW1): ✓ Visible
- Ixion on ws=12 (AW2): ✓ Hidden when viewing AW1
- Rapid AW switching (1→2→3→1) smooth and consistent ✓

---

## Files Changed

| File | Change | Commit |
|------|--------|--------|
| `bin/omarchy-hyprland-workspace-global-switch` | Add focus stealing prevention | `c3d357e` |
| `CRITICAL_BUG_FIX_FOCUS_STEALING_SEP8_2026.md` | Detailed bug analysis | `8f80aab` |

---

## Previous False Leads

**Earlier investigation (Sep 8):**
- Initially blamed: orphaned windows on wrong monitors
- Added: orphaned window detection and migration (commit `6a5725c`)
- Result: Didn't fix the issue because the real bug was focus state, not window location

**Lesson:** The symptom (Ixion stuck on wrong AW) looked like a workspace/window assignment problem, but was actually a focus state corruption issue at a higher level.

---

## How to Test in Production

Test the fix with your normal usage:

```bash
# Do your normal thing:
1. Launch Ixion (AW1 or AW2)
2. Rapid workspace switching: SUPER+1, SUPER+2, SUPER+3, SUPER+1
3. Check that Ixion follows correctly
4. Verify Signal/Teams/WhatsApp visibility matches your AW slot
```

**Expected behavior:**
- Ixion appears on its assigned AW
- Apps on other AWs are hidden
- No stuttering or lag on switches
- Focus remains on the monitor you were using

---

## GitHub

All changes pushed to main:
```
6a5725c  FIX: orphaned window migration (didn't fix the real bug)
c3d357e  CRITICAL FIX: focus stealing prevention (REAL FIX)
8f80aab  docs: detailed analysis
```

---

## Next Steps

1. **Continue normal use** — the fix is live and tested
2. **Monitor for edge cases** — if you find remaining issues, they're likely a different bug
3. **Rapid switching** — stress-test with quick AW changes to confirm stability

Sir, the bug is fixed. Ixion now correctly stays on its assigned workspace.
