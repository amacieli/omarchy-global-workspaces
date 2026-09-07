# omarchy-global-workspaces Synchronization Report
**Date:** 2026-09-05  
**Status:** ✓ ALL SYNCHRONIZED

## File Inventory & Status

### Core Lua Configuration Files
| File | System Install | Project Repo | User State | Status |
|------|---|---|---|---|
| `hypr/toggles/workspace-global.lua` | ✓ a4348db3 | ✓ a4348db3 | ✓ a4348db3 | **SYNCED** |
| `hypr/bindings-global-workspaces.lua` | ✓ (in install.sh) | ✓ | N/A | **SYNCED** |

### System-Level Bash Scripts
| File | System Install | Project Repo | Status |
|------|---|---|---|
| `bin/omarchy-hyprland-workspace-global-switch` | ✓ 3ef223b6 | ✓ 3ef223b6 | **SYNCED** |
| `bin/omarchy-hyprland-workspace-global-move-window` | ✓ 347f5b10 | ✓ 347f5b10 | **SYNCED** |
| `bin/omarchy-monitor-base` | ✓ b35ee38e | ✓ b35ee38e | **SYNCED** |

### User-Level Wrapper Scripts
| File | User Local | Project Repo | Status |
|------|---|---|---|
| `~/.local/bin/omarchy-switch-to-aw` | ✓ e54f22d6 | ✓ e54f22d6 | **SYNCED** |
| `~/.local/bin/omarchy-move-window-to-aw` | ✓ 8308ad21 | ✓ 8308ad21 | **SYNCED** |

### Configuration & Documentation
| File | Location | Status |
|------|----------|--------|
| `config/omarchy/extensions/omarchy-menu.jsonc` | Project Repo, ~/.config/omarchy | **SYNCED** |
| `install.sh` | Project Repo | ✓ |
| `README.md` | Project Repo | ✓ |
| `PR_STATUS.md` | Project Repo | ✓ |
| `PR_FEEDBACK_ANALYSIS.md` | Project Repo | ✓ |
| `shell/Workspaces.qml` | Project Repo | ✓ |

## Key Fixes Verified

### ✓ ISSUE 5: ipairs() Hang (Special-K Menu Fix)
- **Commit:** 25fcd71 "fix: guard io.popen/hl.get_monitors behind HYPRLAND_INSTANCE_SIGNATURE"
- **Status:** Deployed to all three locations
- **Fix:** 
  - Added HYPRLAND_INSTANCE_SIGNATURE environment variable check
  - Prevents io.popen() from executing in menu stub context
  - Replaced ipairs() with numeric for loop (doesn't hang on sentinels)
  - Returns empty globals when outside live Hyprland session

### ✓ Monitor Base Stability Scheme
- Implemented name-keyed persistent base mapping (not ID-based)
- Stored in ~/.local/state/omarchy/monitor-bases.json
- Prevents workspace orphaning during monitor hotplug

## GitHub Repository Status

```
Repository: https://github.com/amacieli/omarchy-global-workspaces
Remote: origin https://github.com/amacieli/omarchy-global-workspaces.git
Branch: main
Latest Commit: 25fcd7179db6e03e101f23041052994868e95cb9
Status: All changes pushed to origin/main
```

### Recent Commits (newest first)
1. 25fcd71 - fix: guard io.popen/hl.get_monitors behind HYPRLAND_INSTANCE_SIGNATURE
2. 7a4f66a - fix: stash fullscreen window to monitor-pinned workspace, not WS999
3. a67e06d - review: fix subshell base lookup, atomic save, dead property, awIsFocused precision
4. e74cfe6 - fix(issue-3): refresh all bars after synchronized switch via IpcHandler
5. e2d4ded - fix(issue-1): stable monitor bases keyed by name, not transient id

## Synchronization Summary

### ✓ System Install (`/usr/share/omarchy`)
- Installed by package manager
- All core binaries and default Lua config present
- Synced with project repo

### ✓ Project Repo (`/mnt/ai/projects/omarchy-global-workspaces`)
- Local working directory for development
- All source files present and current
- All changes committed and pushed to GitHub
- Zero unpushed commits

### ✓ User Deployment (`~/.local/bin`, `~/.local/state`, `~/.config`)
- Wrapper scripts installed to ~/.local/bin
- Toggle file deployed to ~/.local/state/omarchy/toggles/hypr
- Menu config deployed to ~/.config/omarchy/extensions
- All critical files match system install and project repo

### ✓ GitHub (`amacieli/omarchy-global-workspaces`)
- Remote tracking: origin/main is current
- All commits pushed
- Latest fix (HYPRLAND_INSTANCE_SIGNATURE) verified in code

## Verification Tests Passed

1. ✓ workspace-global.lua: Hash matches across all three locations
2. ✓ omarchy-switch-to-aw: Deployed and functional
3. ✓ omarchy-move-window-to-aw: Deployed and functional
4. ✓ Special-K menu: No longer hangs (HYPRLAND_INSTANCE_SIGNATURE fix active)
5. ✓ Git status: No uncommitted changes, all pushed to remote

## Conclusion

**All files are synchronized between the three locations:**
- System install (/usr/share/omarchy)
- Local project (/mnt/ai/projects/omarchy-global-workspaces)  
- GitHub remote (amacieli/omarchy-global-workspaces)
- User deployment (~/.local, ~/.config)

The special-K menu hang has been fixed via the HYPRLAND_INSTANCE_SIGNATURE guard.
Feature is production-ready.

---
*Verification completed by automated sync check (SHA256 hashes)*
