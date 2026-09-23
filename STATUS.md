# omarchy-global-workspaces — Project Status

**Last updated:** 2026-09-23  
**PR:** [omacom/omarchy#12978](https://github.com/omacom/omarchy/pull/12978) — OPEN  
**PR branch:** `amacieli/omarchy` → `feature/global-workspaces-fixes-v2`  
**PR head commit:** `caff3e03`  
**Standalone repo:** [amacieli/omarchy-global-workspaces](https://github.com/amacieli/omarchy-global-workspaces) (`main`)

---

## Current State

The PR is **open and awaiting maintainer review**. All issues raised in the community review (by @llstrk) have been resolved. A response comment was posted to the PR on 2026-09-23.

---

## What the PR Adds

Feature: opt-in global workspace mode for multi-monitor Hyprland setups. When enabled, all monitors switch to the same logical workspace slot (1–10) simultaneously, using stable name-keyed bases that survive monitor hotplug.

### Files in the PR (commit `caff3e03`)

| File | Description |
|---|---|
| `bin/omarchy-switch-to-aw` | Dispatcher: routes SUPER+N to global or local switch |
| `bin/omarchy-move-window-to-aw` | Dispatcher: routes SUPER+SHIFT+N to global or local window move |
| `bin/omarchy-monitor-base` | Allocates/persists stable monitor name→base mappings in `~/.local/state/omarchy/monitor-bases.json` |
| `bin/omarchy-hyprland-workspace-global-switch` | All-monitor slot dispatch (global mode switch callee) |
| `bin/omarchy-hyprland-workspace-global-move-window` | Monitor-relative window move (global mode move callee) |
| `bin/omarchy-ensure-workspaces` | Post-init verifier: re-materialises any missing workspace slots |
| `default/hypr/toggles/workspace-global.lua` | Toggle module: base allocation, workspace materialisation, event hook for universal sync |
| `shell/plugins/bar/widgets/Workspaces.qml` | Bar widget: global-mode aware focus/occupancy mapping |

---

## Community Review Issues — All Resolved

Review posted by **@llstrk** at commit `13bbe094`. Resolved in commit `caff3e03`.

### Issue 1 — Toggle path (FIXED)
- **Problem:** `workspace-global.lua` was at `config/hypr/toggles/` but `omarchy-hyprland-toggle` reads from `$OMARCHY_PATH/default/hypr/toggles/`. Every `omarchy-hyprland-toggle workspace-global on` call hit "Flag not found".
- **Fix:** File moved to `default/hypr/toggles/workspace-global.lua`.

### Issue 2 — Missing helper scripts (FIXED)
- **Problem:** `omarchy-switch-to-aw` and `omarchy-move-window-to-aw` called `omarchy-hyprland-workspace-global-switch`, `omarchy-hyprland-workspace-global-move-window`, `omarchy-monitor-base`, and `omarchy-ensure-workspaces` — none of which were shipped.
- **Fix:** All four added to `bin/`.

### Issue 3 — Bar slot/focus mapping (FIXED)
- **Problem:** `Workspaces.qml` only checked raw IDs 1–10 for focus/occupancy. In global mode, workspace 12 (monitor-2 slot 2) was never shown as focused and its windows didn't contribute to occupied state.
- **Fix:** `Workspaces.qml` rewritten with:
  - `FileView.exists` flag detection (reactive — live toggle, no restart needed)
  - `slotOfId(id) = ((id - 1) % 10) + 1` maps any raw ID to slot 1–10
  - `slotOccupied()` / `slotFocused()` check all IDs mapping to a slot
  - Bar clicks route through `omarchy-switch-to-aw` in global mode
  - Local mode behaviour unchanged

---

## Architecture Notes

### Stable Base Scheme
Each monitor is assigned a permanent workspace base on first connection, stored in `~/.local/state/omarchy/monitor-bases.json` keyed by **monitor OS name** (e.g. `"DP-1": 10`), not by Hyprland's transient numeric ID. Hyprland reassigns numeric IDs on every hotplug ([hyprwm/Hyprland#2601](https://github.com/hyprwm/Hyprland/issues/2601)); name-keyed bases survive this.

```
Workspace ID = monitor_base + slot
Example (3 monitors):
  HDMI-A-1  base=0:  WS 1–10  (slot 1 = WS 1)
  DP-1      base=10: WS 11–20 (slot 2 = WS 12)
  DP-2      base=20: WS 21–30 (slot 3 = WS 23)
```

### Universal Sync via Event Hook
`workspace-global.lua` registers `hl.on("workspace.active", ...)` which fires on **every** workspace switch regardless of source (keybindings, bar clicks, menus, raw `hyprctl`, other tools). The handler syncs all monitors to the same slot. Re-entrancy is safe: only dispatches to monitors showing the wrong workspace, so each pass reduces mismatches monotonically (never ping-pongs).

### Stub Safety
`workspace-global.lua` gates all Hyprland-dependent calls behind `HYPRLAND_INSTANCE_SIGNATURE` so `omarchy-menu-keybindings` can evaluate it under a stub environment without blocking on a nonexistent Hyprland socket.

---

## Enabling Global Mode (after PR merges)

```bash
omarchy-hyprland-toggle workspace-global on
# hyprctl reload is called automatically by the toggle command
```

To disable:
```bash
omarchy-hyprland-toggle workspace-global off
```

---

## Local Testing (before PR merges)

Use `install.sh` in this repo root. Mirrors the PR exactly.

```bash
cd /mnt/ai/projects/omarchy-global-workspaces
git checkout main
bash install.sh
```

`install.sh` installs all 7 PR files to their correct system locations (with sudo fallback for Omarchy-owned paths) and backs up the original `Workspaces.qml`.

---

## Key File Locations

| Location | Purpose |
|---|---|
| `/mnt/ai/projects/omarchy-global-workspaces/` | Standalone project repo (`main` branch) |
| `github-fork` remote | `amacieli/omarchy` (the fork the PR is open from) |
| `upstream` remote | `omacom/omarchy` (target repo) |
| PR branch | `feature/global-workspaces-fixes-v2` on `github-fork` |
| `~/.local/state/omarchy/monitor-bases.json` | Persistent monitor name→base map (runtime) |
| `~/.local/state/omarchy/toggles/hypr/workspace-global.lua` | Toggle flag file (runtime, created by toggle command) |

---

## Next Steps

- [ ] Wait for @llstrk re-review / maintainer pickup
- [ ] If requested: add tests under `test/shell.d/` (Omarchy test convention)
- [ ] If requested: update PR description body to summarise the caff3e03 fixes at a glance
