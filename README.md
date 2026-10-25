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
