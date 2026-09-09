# Global Workspaces PR Workflow & Synchronization

**Status:** Master repository for global workspaces feature  
**Last Updated:** September 9, 2026  
**PR Target:** https://github.com/omacom/omarchy/pull/10199

## Repository Structure

This folder (`/mnt/ai/projects/omarchy-global-workspaces/`) is now the **master development repository** for the global workspaces feature. All code changes are developed here and periodically synced back to the upstream PR.

### Previous Workflow (Deprecated)

Previously, `/mnt/ai/projects/omarchy-pr-fork/` was used as a staging area for the PR. This has been consolidated into this repository.

## How This Repository Works

### Directory Layout

```
.
├── shell/
│   └── Workspaces.qml              # QML widget with stable monitor base map
├── bin/omarchy-workspace-scripts/  # Support scripts for global workspace switching
│   ├── omarchy-hyprland-workspace-global-switch    # Main entry point (with retries)
│   ├── omarchy-monitor-base                        # Stable monitor identity mapping
│   ├── omarchy-ensure-workspaces                   # Pre-materialize WS 1-30
│   ├── omarchy-recover-stranded-windows            # Post-disconnect recovery
│   ├── omarchy-init-global-workspaces              # Safe rule registration
│   ├── omarchy-diagnose-workspace-state            # Debugging tool
│   └── [other helpers]
├── hypr/
│   ├── autostart.lua                               # Workspace materialization hook
│   ├── bindings-global-workspaces.lua              # Global workspace keybindings
│   └── toggles/workspace-global.lua                # Toggle file template
├── config/omarchy/extensions/
│   └── omarchy-menu-global-workspaces.jsonc        # Menu integration
├── WORKFLOW_AND_PR_SYNC.md                         # This file
├── EDGE_CASES_RESOLVED.md                          # Detailed edge case documentation
└── [git history and commit logs]
```

## Commit History

### Major Milestones

1. **b9f53d4b** - `Workspaces.qml: Add global workspace sync for multi-monitor setups`
   - Initial PR commit (Sep 4, 2026)
   - Dual-mode operation (global + fallback)
   - Raw offset scheme (monitorId * 10)

2. **d8fffbf2** - `Doc: Findings & fix deployment log` (Sep 9, 2026)
   - Documented initial deployment findings
   - Identified Hyprland API quirks

3. **bd460c13** - `fix: add edge case handling for workspace switching and monitor hotplug`
   - **CURRENT**: Comprehensive edge case fixes (Sep 9, 2026, 11:42 UTC)
   - Stable monitor base map (OS names, not Hyprland IDs)
   - Retry logic for workspace rule races
   - Workspace pre-materialization
   - Stranded window recovery
   - 1043 lines of new code + supporting scripts

## Edge Cases Addressed

See `EDGE_CASES_RESOLVED.md` for detailed explanations of each fix.

### Quick Summary

| Issue | Problem | Solution |
|-------|---------|----------|
| 4 | `set_workspace()` ignores cursor warp | Use `hl.dsp.focus()` instead |
| 5 | `set_workspace()` silently no-ops | Pre-materialize all workspaces |
| 6 | Workspace rules race on immediate check | Retry with 100-200ms backoff |
| 7 | Can't distinguish reload from restart | Track HYPRLAND_INSTANCE_SIGNATURE |
| 8 | Windows stranded after disconnect | Recover via `(ws_id - 1) % slots + 1` |

Plus: **Stable monitor identity** via `~/.local/state/omarchy/monitor-bases.json` (major architectural fix)

## Development Workflow

### Making Changes Locally

1. Edit files in this directory
2. Test on your system
3. Commit with descriptive message
4. Push to `origin main`

### Syncing to Upstream PR

**To push changes back to the PR branch** (`feature/global-workspaces-widget` in `omacom/omarchy`):

```bash
# 1. Ensure changes are committed in main
cd /mnt/ai/projects/omarchy-global-workspaces
git log --oneline -1

# 2. Identify the file paths to push
# Core: shell/plugins/bar/widgets/Workspaces.qml
# Binaries: bin/omarchy-workspace-scripts/*
# Configs: config/hypr/*, config/omarchy/extensions/*

# 3. The PR fork is now deleted, so manual sync is required
#    (Or re-establish the pr-fork as needed for future work)

# For now, the latest fix commit (bd460c13) is already in the PR
# New changes require manual cherry-pick or rebasing
```

### If You Need to Update the PR Again

```bash
# Option A: Cherry-pick method
cd /mnt/ai/projects/omarchy-global-workspaces
git log --oneline -5  # Find commit hash to push

# Clone the PR fork again, or use the upstream directly
git remote add upstream-pr https://github.com/amacieli/omarchy.git
git fetch upstream-pr feature/global-workspaces-widget
git cherry-pick <commit-hash>
git push upstream-pr feature/global-workspaces-widget

# Option B: Rebase method (if you need to update an older commit)
git rebase -i <upstream-base>
git push upstream-pr feature/global-workspaces-widget --force-with-lease
```

## GitHub PR Status

**PR:** https://github.com/omacom/omarchy/pull/10199  
**Base:** `omacom/omarchy` upstream (`quattro` branch)  
**Status:** OPEN (awaiting review)  
**Commits in PR:** 2
  - `b9f53d4b`: Initial widget implementation
  - `feefe564`: Edge case fixes (synced from this repo as `bd460c13`)

### Reviewers

**isaac30503** - Extended testing, identified edge cases 4-8. Review pending.

### How to Comment on PR

1. Go to https://github.com/omacom/omarchy/pull/10199
2. Scroll to comment box at bottom
3. Tag `@isaac30503` with update notes
4. Click "Comment"

GitHub will notify him automatically.

## Deleted Files & Cleanup

### Removed

- `/mnt/ai/projects/omarchy-pr-fork/` **DELETED** (Sep 9, 2026, 16:00 UTC)
  - Was staging area for PR commits
  - No longer needed; all history consolidated here

- `/mnt/ai/projects/omarchy-global-workspaces-archive-20260903-194233/` (unchanged)
  - Backup from Sep 3, 2026 (kept for reference)

## Key Files to Review

### For QML/Widget Logic
- `shell/Workspaces.qml` — Stable base map, focus/occupied state, slot lookup

### For Switch/Move Logic
- `bin/omarchy-workspace-scripts/omarchy-hyprland-workspace-global-switch` — Main dispatcher
- `bin/omarchy-workspace-scripts/omarchy-hyprland-workspace-global-move-window` — Window moves

### For Recovery & Diagnostics
- `bin/omarchy-workspace-scripts/omarchy-recover-stranded-windows` — Post-hotplug recovery
- `bin/omarchy-workspace-scripts/omarchy-diagnose-workspace-state` — Debugging tool

### For Config
- `hypr/autostart.lua` — Workspace materialization on startup
- `hypr/toggles/workspace-global.lua` — Toggle file template

## Testing Checklist

Before pushing to PR, verify:

- [ ] Global mode: all monitors switch together when clicking a slot
- [ ] Local mode fallback: works if toggle file is absent
- [ ] Hotplug: external monitor connect/disconnect doesn't break focus
- [ ] Clamshell: works with only internal display
- [ ] Fullscreen=2 blocking: doesn't cause focus jumps
- [ ] Window recovery: `omarchy-recover-stranded-windows` recovers stale windows
- [ ] Diagnostics: `omarchy-diagnose-workspace-state` shows accurate state

## Future Work

### Potential Improvements

1. **Persistent monitor bases** — Currently stored in JSON file, could use systemd/XDG state
2. **Race condition tuning** — Retry backoff timing could be optimized based on Hyprland version
3. **Per-monitor workspace indicators** — Show which monitor owns which workspace
4. **Lua integration** — Native hyprctl eval instead of shell-based dispatch
5. **Documentation** — User guide for clamshell + multi-monitor modes

### Known Limitations

- Requires Hyprland 0.56.x+ (workspace rule API)
- Hyprland IDs are never reused after hotplug (see #2601), so bases persist correctly
- `HYPRLAND_INSTANCE_SIGNATURE` changes on real restart but not on `hyprctl reload`

## Useful Commands

```bash
# Check current workspace state
cd /mnt/ai/projects/omarchy-global-workspaces
bin/omarchy-workspace-scripts/omarchy-diagnose-workspace-state

# Recover stranded windows after unexpected disconnect
bin/omarchy-workspace-scripts/omarchy-recover-stranded-windows

# View stable monitor base map
cat ~/.local/state/omarchy/monitor-bases.json | jq .

# Test workspace pre-materialization
bin/omarchy-workspace-scripts/omarchy-ensure-workspaces

# View git history for recent changes
git log --oneline --all -15
```

## Contact & Notes

**Adam (you)** — Primary developer  
**isaac30503** — Extended tester, edge case finder  

If you have questions about implementation details, see commit messages and inline code comments (especially in the switch script).

---

**Last sync:** Sep 9, 2026, 15:42 UTC  
**Files changed (latest): 14  
**Lines added: 1043  
**Commits in this repo: 6+ (see `git log`)
