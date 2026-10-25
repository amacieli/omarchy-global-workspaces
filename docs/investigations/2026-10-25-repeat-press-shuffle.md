# Repeat-press workspace shuffle (2026-10-25)

Symptom (reported on the pre-plugin install): pressing `SUPER+N` for the same
slot two or three times in a row makes windows land on other monitors / other
"apparent workspaces".

**Status: root cause partly confirmed, nothing fixed yet.** No windows were
observed moving (none were on the affected workspaces during the test); workspace
stranding and wrong-monitor creation were reproduced.

## What is actually installed (not the repo version)

The live setup runs older code than this repo:

- `/usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch` (11 KB). Per
  monitor, on every press, unconditionally: move "orphan" windows by address,
  `workspace.move({workspace=base+N, monitor=M})`, then `focus({workspace=base+N})`,
  with a fullscreen=2 stash on `base+99`. Non-focused monitors first (highest base
  first), originally focused monitor last.
- `~/.local/bin/omarchy-switch-to-aw` and `omarchy-move-window-to-aw` shadow the
  `/usr/share` ones on PATH (same routing logic).
- `~/.local/state/omarchy/toggles/hypr/workspace-global.lua` is an older copy than
  `hypr/workspace-global.lua`: no `workspace.active` sync hook, no hotplug handlers.
  `omarchy-hyprland-toggle` copies it once; later fixes do not reach it until the
  toggle is turned off and on.
- `~/.config/hypr/bindings.lua` rebinds `SUPER+N` / `SUPER+SHIFT+N` to the wrappers.
- `~/.config/hypr/autostart.lua` focuses raw workspaces 1..30 in a loop on every
  config load (including every `hyprctl reload`), all on the focused monitor.

Hyprland 0.56.2. `monitor-bases.json`: `HDMI-A-1: 0, DP-1: 10, DP-2: 20`.

## Evidence

Start state: HDMI-A-1 on ws 1 (focused), DP-1 on 5, DP-2 on 21 (already out of
sync; raw `5` sits on DP-1 whose range is 11-20). Only 3 workspaces existed.
`hyprctl workspacerules -j` listed 3 rules (`21`, `2`, `30`) with no monitor or
persistent fields, although the toggle registers 30 persistent rules.

`omarchy-switch-to-aw 1` x3 (snapshots in this directory):

| | HDMI-A-1 | DP-1 | DP-2 |
|---|---|---|---|
| before | 1 | 5 | 21 |
| press 1 | 1 | 5 | **11** |
| press 2, 3 | 1 | 5 | 11 |

DP-2 ended on 11 (DP-1's range) and DP-1 never reached 11.

Hand-run dispatches (state restored afterwards):

1. `focus({workspace="21"})` (owned by DP-2) switched DP-2 to 21 **and moved
   keyboard focus to DP-2**.
2. `focus({workspace="11"})` / `"12"` with DP-2 focused created them on **DP-2**,
   the focused monitor, not DP-1.
3. After leaving them, 11 and 12 were destroyed: not persistent.

## Diagnosis

- The switch script assumes focusing a workspace on a non-focused monitor does not
  steal focus. It does. After the DP-2 step the focused monitor is DP-2, so the
  next step (DP-1's empty ws 11) is created on DP-2. DP-1 is left on a stray raw
  workspace. Empty slot workspaces therefore get created on whichever monitor has
  focus, and anything opened/moved there ends up on the wrong monitor.
- Persistence/pinning is not in effect, so empty slots do not survive and are not
  bound to their monitor. Cause unknown (see below).
- Every press re-runs the whole sequence, with no skip for monitors already on the
  target. `workspace.move` on an existing workspace removes it from its monitor,
  which then falls back to a default workspace; the stash/restore is three
  non-atomic dispatches. These can move windows but were not reproduced.
- `autostart.lua`'s 1..30 loop creates every workspace on the focused monitor on
  each reload, unpinned, and they vanish when left.

## Next steps

1. Find why `hl.workspace_rule({workspace, monitor, persistent=true})` does not
   take effect in 0.56.2 (check argument names against the Hyprland Lua docs,
   `hyprctl workspacerules -j` after reload, whether later rules replace earlier
   ones). Read-only.
2. Make the switch deterministic: focus monitor first, then workspace; skip
   monitors already on target; restore the original monitor last. Drop
   `workspace.move` and the orphan-window moves once pinning works.
3. Remove the 1..30 loop from `~/.config/hypr/autostart.lua`.
4. Check the plugin's `workspace.active` hook (this repo) for the same
   wrong-monitor creation; it is untested live.
5. Reproduce with a window on a stranded slot, with the user's agreement.

## Safe-repro notes

Snapshot `hyprctl monitors/workspaces/clients -j` first. Restore by focusing the
original workspaces, focused monitor last. Never use anything that closes windows.
