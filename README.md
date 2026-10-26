# Global Workspaces

An [Omarchy](https://omarchy.org) shell plugin that makes workspaces **global across monitors**: press `SUPER+3` and *every* monitor switches to its own slot 3, instead of only the focused one. The bar widget shows one row of slots 1–10 that follows the mode.

This started as a pull request against Omarchy itself ([omacom/omarchy#12978](https://github.com/omacom/omarchy/pull/12978); history in [`amacieli/omarchy-global-workspaces-old`](https://github.com/amacieli/omarchy-global-workspaces-old)) and is now a standalone plugin.

> **Status: first draft (0.1.0).** The scripts and the Hyprland Lua carry over from the PR and are covered by shell tests. The plugin packaging and the bar widget port have been validated (`omarchy plugin validate`) but not yet exercised in a live shell.

## How it works

Each monitor owns ten workspaces. A monitor gets a permanent *base* the first time it is seen, stored by monitor **name** in `~/.local/state/omarchy/monitor-bases.json` (Hyprland reuses no monitor ids across hotplug, so ids are unusable as keys). Slot `N` on monitor `M` is workspace `base(M) + N`, and the slot is recoverable from any id as `(id - 1) % 10 + 1`.

| Piece | File | Role |
|---|---|---|
| Bar widget | `BarWidget.qml` | Slot row; click switches all monitors in global mode |
| Hyprland config | `hypr/workspace-global.lua` | Allocates bases, materialises persistent workspaces, syncs monitors on `workspace.active`, handles hotplug, rebinds the workspace keys |
| Wrappers | `bin/omarchy-switch-to-aw`, `omarchy-move-window-to-aw` | Keybinding targets; route by whether global mode is on |
| Helpers | `bin/omarchy-hyprland-workspace-global-*`, `omarchy-monitor-base`, `omarchy-ensure-workspaces` | Switch/move across monitors, base allocation, workspace retry |
| Switch | `bin/omarchy-global-workspaces` | `on` / `off` / `toggle` / `status` |

Details and design notes: [docs/DESIGN.md](docs/DESIGN.md).

## Install

```sh
omarchy plugin add https://github.com/amacieli/omarchy-global-workspaces.git --enable
```

Replace the built-in workspace indicator so you don't get two rows:

```sh
omarchy plugin disable omarchy.workspaces
omarchy bar put io.github.amacieli.global-workspaces --section left
```

Turn global mode on (installs the Hyprland flag and reloads Hyprland):

```sh
~/.config/omarchy/plugins/io.github.amacieli.global-workspaces/bin/omarchy-global-workspaces on
```

Optionally put it on your `PATH`:

```sh
ln -s ~/.config/omarchy/plugins/io.github.amacieli.global-workspaces/bin/omarchy-global-workspaces ~/.local/bin/
```

## Usage

| Keys | Global mode |
|---|---|
| `SUPER+1…0` | Every monitor switches to slot N |
| `SUPER+SHIFT+1…0` | Move the window to slot N on the focused monitor, then follow |
| `SUPER+SHIFT+ALT+1…0` | Same, without following |
| `SUPER+CTRL+TAB` | Former workspace, per monitor |

`omarchy-global-workspaces off` removes the flag and Hyprland returns to Omarchy's native per-monitor bindings.

The bar widget shows slots 1–5, like stock Omarchy. `SUPER+6…0` still work; those slots just aren't drawn.

## Modes

| Mode | Command | Behaviour |
|---|---|---|
| Local | `omarchy-global-workspaces off` | Omarchy's native per-monitor workspaces |
| Global | `omarchy-global-workspaces on` | Slot N on every monitor at once |
| Global Persisted | `omarchy-global-workspaces persisted` | Global, plus app placement is remembered and restored at login |

`omarchy-global-workspaces mode` prints `local`, `global` or `persisted`.

To pick the mode from the Omarchy menu (Trigger › Toggle › Workspace Mode), add entries to `~/.config/omarchy/extensions/omarchy-menu.jsonc`. A plugin cannot install menu entries itself:

```jsonc
"trigger.toggle.workspace-mode":        { "icon": "󱂬", "label": "Workspace Mode" },
"trigger.toggle.workspace-mode.global": { "icon": "󱂬", "label": "Global",
  "checked": "[[ $(omarchy-global-workspaces mode) == global ]]",    "action": "omarchy-global-workspaces on" },
"trigger.toggle.workspace-mode.global-persisted": { "icon": "󱂬", "label": "Global Persisted",
  "checked": "[[ $(omarchy-global-workspaces mode) == persisted ]]", "action": "omarchy-global-workspaces persisted" },
"trigger.toggle.workspace-mode.local":  { "icon": "󱂬", "label": "Local",
  "checked": "[[ $(omarchy-global-workspaces mode) == local ]]",     "action": "omarchy-global-workspaces off" }
```

(use the full path to the script if it is not on your `PATH`).

### Global Persisted

While this mode is on, Hyprland events run `bin/omarchy-gws-persist`:

- **Recording** (debounced, on window open/move/focus): per app class, the monitor *name*, slot 1–10, floating state and geometry go to `~/.local/state/omarchy/global-workspaces/layout.json`.
- **Restoring**: when a window of a recorded class opens (for example from autostart after login), it is moved to its recorded monitor and slot. The n-th window of a class takes the n-th recorded entry. Floating windows also get their position and size back.
- **It does not launch apps.** It places windows that you or your autostart open.
- **Tiled order is not restored.** Tiled windows land on the right monitor and slot; their order within the workspace follows the order the apps open.
- Recording is merge-only per class, so closing apps at logout cannot erase the layout; for the first 3 minutes after login a class never loses recorded windows while its other windows are still opening. Entries unseen for 30 days are dropped.
- A monitor that is not connected is skipped.

## Uninstall

```sh
omarchy-global-workspaces off
omarchy plugin remove io.github.amacieli.global-workspaces
omarchy plugin enable omarchy.workspaces
```

`~/.local/state/omarchy/monitor-bases.json` is left in place so monitors keep their ranges if you reinstall; delete it to reset.

## Security and permissions

Plugins run unsandboxed inside the shell. This one:

- runs the scripts in `bin/` (via `hyprctl`, `python3`) on keypress and from the bar widget;
- writes one file, `~/.local/state/omarchy/toggles/hypr/workspace-global.lua`, which Hyprland **executes as Lua** on every reload, plus `monitor-bases.json` in the same state tree;
- needs no sudo, no network, and no packages beyond `python3` and `hyprctl`.

Plugin installation never runs hooks, so enabling global mode is a separate, explicit command.

## Compatibility

Targets Omarchy's Quattro shell and Hyprland's Lua config (`hl.*` API, 0.56+). Omarchy's own workspace handling is changing upstream (per-monitor workspace blocks in the built-in widget); this plugin keeps its own widget and bindings and does not depend on that code.

The keybindings in `workspace-global.lua` replace the workspace keys *after* your `hypr/bindings.lua` loads, so personal overrides of exactly those keys lose while global mode is on.

## Development

```sh
tests/run                         # shell tests, no Hyprland session needed
omarchy plugin validate .
```

## License

MIT, see [LICENSE](LICENSE).

## Notes

Background on the repeated-`SUPER+N` investigation and its fixes: [docs/investigations/2026-10-25-repeat-press-shuffle.md](docs/investigations/2026-10-25-repeat-press-shuffle.md).
