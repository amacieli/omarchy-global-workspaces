# Installation Report: Ixion Workspace Visibility Fix (Sep 8, 2026)

## Status: ✅ COMPLETE

All changes have been committed, pushed to GitHub, and installed on your system.

---

## Changes Committed

**Commit:** `6a5725c`

```
FIX: omarchy-hyprland-workspace-global-switch — migrate orphaned windows before workspace reassignment

When windows on a workspace are physically on different monitors than Hyprland's
metadata says, workspace.move() alone leaves them in a 'shadow' state. On the next
switch, this causes visibility loss and rendering desync (windows appear but are
invisible or frozen).

Symptom: Ixion (fullscreen Steam game on DP-1) remains visible on third monitor
after switching from AW2 back to AW1, with other windows becoming invisible.

Solution: Before calling workspace.move(), find all windows assigned to the target
workspace but physically on other monitors, and migrate them explicitly. This
ensures window and workspace metadata are synchronized before focus changes.

Added diagnostics:
- bin/omarchy-diagnose-workspace-state: inspect workspace/window sync mismatches
- BUG_IXION_VISIBILITY_SEP8_2026.md: detailed root cause analysis and reproduction
- IXION_BUG_FIX_SUMMARY.md: implementation status and testing guide

Fixes: Ixion visibility loss when switching between global workspaces (Sep 8, 2026)
```

**Push:** GitHub remote main updated
```
   3aed3c7..6a5725c  main -> main
```

---

## Files Installed

### System-wide (root, /usr/share/omarchy/bin/)

✅ `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch` (9.8K)
   - Core fix: orphaned window detection and migration

✅ `/usr/share/omarchy/bin/omarchy-diagnose-workspace-state` (1.9K)
   - Diagnostic tool to inspect workspace/window sync

### User-level (~/.local/bin/)

✅ `~/.local/bin/omarchy-diagnose-workspace-state` (1.9K)
   - User copy for quick access

All existing user scripts remain installed and functional.

---

## How to Test

### Quick Test (while Hyprland is running)

1. Run Ixion on DP-1 in a specific AW slot (e.g., AW1):
   ```bash
   steam steam://rungameid/1113120 &
   ```

2. Verify workspace state (diagnostic tool):
   ```bash
   omarchy-diagnose-workspace-state
   ```
   Look for rows with `[MISMATCH!]` — there should be **none** after the fix.

3. Switch workspaces:
   - SUPER+2 → Ixion moves to DP-1's AW2 ✓
   - SUPER+1 → Ixion disappears from third monitor ✓
   - Other windows on third monitor remain visible ✓

4. Stress test (rapid switches):
   ```bash
   for i in {1..5}; do
     sleep 0.5
     omarchy-switch-to-aw $((i % 3 + 1))
   done
   ```
   Ixion should follow cleanly without stuttering or disappearing.

### Production Validation

- [ ] Ixion stays on correct monitor after AW2 → AW1 switch
- [ ] Other windows on DP-1 remain visible during switches
- [ ] No "shadow" workspace states (run diagnostic tool before/after)
- [ ] Rapid workspace cycling works smoothly
- [ ] Fullscreen games (Ixion) render without corruption

---

## How to Revert (if needed)

The fix is backward-compatible. If you need to revert:

```bash
cd /mnt/ai/projects/omarchy-global-workspaces
git revert 6a5725c
sudo bash install.sh  # Reinstall the reverted version
```

---

## GitHub Link

**Repository:** https://github.com/amacieli/omarchy-global-workspaces  
**Latest commit:** 6a5725c  
**Branch:** main

---

## Documentation

All investigation notes are in the project root:

- `BUG_IXION_VISIBILITY_SEP8_2026.md` — Detailed root cause + reproduction steps
- `IXION_BUG_FIX_SUMMARY.md` — Implementation summary + testing guide
- `bin/omarchy-diagnose-workspace-state` — Diagnostic script (self-documented)

---

## Next Steps

1. **Test in production:** Use Ixion to verify the fix resolves your switching issue.
2. **Run diagnostics:** If you see mismatches, collect output and we'll dig deeper.
3. **Feedback:** Let me know if this fixes the issue completely or if edge cases remain.

Ready for testing, sir.
