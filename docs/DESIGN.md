# Design notes

## Stable-base scheme

The earlier scheme used `monitorId * 10`. Hyprland does not reuse monitor ids after hotplug (hyprwm/Hyprland#2601), so unplugging and replugging a monitor gave it a new id and orphaned its occupied workspaces. Bases are now keyed by monitor **name** (`eDP-1`, `DP-2`, …):

```json
{ "eDP-1": 0, "HDMI-1": 10, "DP-2": 20 }
```

- A new monitor gets the lowest unused multiple of 10. Bases are never reassigned or freed.
- Workspace for slot N on monitor M: `bases[M] + N`.
- Slot from id: `(id - 1) % 10 + 1`. The bar widget uses this to collapse every monitor's workspaces onto slots 1–10.
- `omarchy-monitor-base` manages the file from the shell; `hypr/workspace-global.lua` does the same in pure Lua during config evaluation (no subprocess, no IPC round trip). Writes are temp-file + rename.

## Sync

`hl.on("workspace.active")` catches every workspace change regardless of source (keys, bar clicks, `hyprctl`, other tools) and dispatches each monitor that is not on the target slot. It re-enters safely: only mismatched monitors are dispatched, so each pass strictly reduces mismatches.

Focusing a workspace on another monitor moves keyboard focus and pointer there, so the handler records the focused monitor first and refocuses it after all dispatches, including when it was already on the target slot.

## Persistent workspaces

`hl.workspace_rule({ persistent = true })` is registered for every slot of every monitor so switching to an empty slot never silently no-ops. Rules do not materialise synchronously, so `omarchy-ensure-workspaces` re-verifies after a short delay (and after hotplug).

## Hotplug

`monitor.added` / `monitor.removed` (Hyprland 0.56+) rebuild the monitor list, allocate a base for new monitors, and re-run workspace materialisation. Scripts only dispatch to connected monitors, so disconnected saved bases do not create stray workspaces.

## Stub safety

`omarchy-menu-keybindings` evaluates Hyprland Lua under a stub to read binding metadata. `workspace-global.lua` returns early unless `HYPRLAND_INSTANCE_SIGNATURE` is set, and uses numeric `for` loops instead of `ipairs()` (which hangs on the stub's catch-all `__index`, omacom/omarchy#7025). A side effect: the keybinding menu shows Omarchy's default workspace bindings, not the global-mode ones.

## Flag file and keybindings

Global mode is a file in `~/.local/state/omarchy/toggles/hypr/`, which `toggles.lua` loads after the default and user bindings. The plugin cannot install files outside its checkout on `omarchy plugin add`, so `omarchy-global-workspaces on` copies `hypr/workspace-global.lua` there with `@PLUGIN_DIR@` replaced by the checkout path. Keybindings are `hl.unbind` + `hl.bind` pairs, since binding a key twice fires both dispatchers. The bar widget and the wrapper scripts both treat the presence of the flag file as "global mode on", and the widget re-probes every 2 s because `FileView.watchChanges` can miss events after rapid changes.
