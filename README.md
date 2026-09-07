# omarchy-global-workspaces

Global workspace switching for [Omarchy](https://omarchy.com) — a multi-monitor
Hyprland setup where pressing SUPER+1 through SUPER+5 moves **every** monitor to
the same apparent workspace simultaneously.

## Concept

Omarchy and Hyprland use two different workspace concepts:

- **AW (Apparent Workspace)**: what you see. AW1 through AW5 are the five slots
  shown on the quickshell bar. Switching to AWN moves every monitor together.
- **WS (Hyprland Workspace)**: the underlying integer ID. In global mode each
  physical monitor owns an exclusive range (offset = monitorId × 10):
    - monitor 0  →  WS  1-10
    - monitor 1  →  WS 11-20
    - monitor 2  →  WS 21-30
  So AWN on monitor M = WS(M×10 + N).

In **global mode** all three bars show the same five buttons (1–5). Clicking AW2
sends every monitor to its slot-2 workspace simultaneously (WS2, WS12, WS22).
Apps on AW1 disappear; apps on AW2 appear, exactly where you left them, on
whichever monitors you placed them.

In **local mode** (toggle off) everything falls back to stock Omarchy behaviour —
each monitor switches independently.

## What's installed

### System files (require sudo)

| Destination | Description |
|---|---|
| `/usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml` | Bar widget — AW-aware, shows 5 buttons, global/local reactive |
| `/usr/share/omarchy/default/hypr/toggles/workspace-global.lua` | Hyprland toggle flag — stores sorted monitor list at reload time |
| `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch` | Switch all monitors to slot N simultaneously |
| `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-move-window` | Move focused window to slot N on its own monitor |

### User files (no sudo)

| Destination | Description |
|---|---|
| `~/.local/bin/omarchy-switch-to-aw` | Runtime-aware wrapper: global → global-switch, local → hyprctl workspace |
| `~/.local/bin/omarchy-move-window-to-aw` | Runtime-aware wrapper: global → global-move-window, local → movetoworkspacesilent |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | Menu entries: Trigger → Toggle → Workspace Mode → Global / Local |
| `~/.config/hypr/bindings.lua` | Hotkey block: SUPER+1-10 and SUPER+SHIFT+1-10 |

## Install

```bash
git clone https://github.com/amacieli/omarchy-global-workspaces.git
cd omarchy-global-workspaces
bash install.sh
```

The install script is idempotent — safe to re-run after updates.

## Enable global mode

After install, enable via the Omarchy menu:

    Trigger → Toggle → Workspace Mode → Global

Or from a terminal:

    omarchy-hyprland-toggle workspace-global on

## Hotkeys

| Key | Action |
|---|---|
| SUPER+1 … SUPER+5 | Switch to Apparent Workspace N (all monitors move together in global mode) |
| SUPER+SHIFT+1 … SUPER+SHIFT+5 | Move focused window to AW N silently (stays on its current monitor) |

Both hotkeys check the toggle flag at the moment the key is pressed — switching
between global and local mode takes effect immediately with no Hyprland reload.

## Recovery and maintenance

### Stranded windows after monitor disconnect

When an external monitor disconnects, windows on its workspaces become inaccessible.
To recover them:

```bash
omarchy-recover-stranded-windows
```

This moves each stranded window to the same logical slot (1-5) on your laptop
panel or another available monitor, preserving its workspace organization.

### Ensuring workspaces exist

The startup logic automatically materializes persistent workspaces on all connected
monitors. If you hotplug a new monitor and switching to an empty slot doesn't work,
run:

```bash
omarchy-ensure-workspaces
```

This verifies that all workspace slots exist and refreshes the bar indicators.

## How the switch script works

`omarchy-hyprland-workspace-global-switch` handles two Hyprland edge cases:

1. **Workspace theft** — Hyprland can steal focus to whichever monitor currently
   *owns* a workspace when you dispatch `focus({ workspace = N })`. The script
   pins each workspace to its target monitor with `workspace.move` before
   focusing, preventing this.

2. **Fullscreen=2 blocker** — A true-fullscreen window (fullscreen mode 2)
   silently blocks workspace switches on its monitor. The script detects it by
   address, stashes it to WS999 (without changing focus), switches the workspace,
   then restores the window to its original workspace by address.

Monitors are processed highest-id first, focused monitor last, so keyboard
focus ends up on the monitor you were using.

## File layout

```
omarchy-global-workspaces/
  install.sh                              install / update script
  README.md                               this file
  bin/
    omarchy-hyprland-workspace-global-switch       system script
    omarchy-hyprland-workspace-global-move-window  system script
    omarchy-switch-to-aw                           user wrapper (toggle-aware)
    omarchy-move-window-to-aw                      user wrapper (toggle-aware)
  shell/
    Workspaces.qml                        bar widget replacement
  hypr/
    toggles/
      workspace-global.lua               Hyprland toggle flag
    bindings-global-workspaces.lua       hotkey block (appended to user bindings)
  config/
    omarchy/extensions/
      omarchy-menu.jsonc                 menu entries
```
