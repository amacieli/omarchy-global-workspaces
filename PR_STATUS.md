# PR Status — omarchy-global-workspaces

## PR to basecamp/omarchy

**Status:** OPEN — Awaiting Code Owner Review

### PR Details
- **URL:** https://github.com/basecamp/omarchy/pull/[number] (via amacieli fork)
- **Repository:** basecamp/omarchy
- **Branch:** `feature/global-workspaces-widget` → `quattro`
- **Commit:** b9f53d4 — "Workspaces.qml: Add global workspace sync for multi-monitor setups"
- **Created:** 2026-09-04

### What's in the PR
- **Single file change:** `/shell/plugins/bar/widgets/Workspaces.qml`
- **Scope:** Widget layer only (opt-in via toggle file)
- **Backward compatibility:** 100% — falls back to stock behavior if toggle absent
- **Impact:** 179 insertions, 21 deletions

### Code Owners Requested
- dhh (David Heinemeier Hansson)
- ryanrhughes (Ryan Hughes)

### Next Steps
1. **Waiting for:** Code owner review and approval
2. **Possible questions:** 
   - External script requirement (omarchy-hyprland-workspace-global-switch)
   - Full feature inclusion vs widget-only
   - Testing on multi-monitor setups
3. **Response strategy:** Reference this repo (omarchy-global-workspaces) for complete implementation
4. **Future PRs:** Will contribute supporting scripts and config after widget is merged

### Local Fork Setup
```bash
# Location: /mnt/ai/projects/omarchy-pr-fork/
# Remote: origin = https://github.com/amacieli/omarchy.git (your fork)
#         upstream = https://github.com/basecamp/omarchy.git (basecamp canonical)
# Branch: feature/global-workspaces-widget (on quattro)
```

### Related Discussion
- **GitHub:** https://github.com/basecamp/omarchy/discussions/8412 (linked workspaces for dual-monitor)
- **Your repo:** https://github.com/amacieli/omarchy-global-workspaces
