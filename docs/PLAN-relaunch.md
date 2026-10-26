# Plan: relaunch recorded apps in Global Persisted mode

Status: **plan only, no code written.** Today Global Persisted
(`bin/omarchy-gws-persist`) records where each app's window lives and puts the
window back when it opens, but it does not start anything. This plan covers
starting the apps too.

## Goal

At login, in Global Persisted mode, offer to start the apps that were open last
session, with the user choosing which ones, so that the existing placement logic
puts each window on its recorded monitor and slot. The launch commands should come from what the Omarchy menu already points
at, not from guessing at process command lines.

## Findings that shape the design

Checked on this machine, 2026-10-26.

1. **The menu's "Apps" entry is a provider over `.desktop` files**
   (`omarchy-menu.jsonc`: `"apps": {... "provider": "apps"}`). The launcher the
   menu offers is therefore the `Exec=` of a `.desktop` entry, from
   `~/.local/share/applications/` and `/usr/share/applications/`. Keying off
   `.desktop` files is "keying off whatever the menu points at". Hand-written
   `action` entries in `omarchy-menu.jsonc` (user extensions) are the second
   source.
2. **Many `Exec=` lines are Omarchy wrappers**, which is what we want to reuse:
   `omarchy-launch-webapp "<url>"` (Teams, Excel, Outlook, ...), `steam
   steam://rungameid/N`, and `foot --app-id=TUI.tile ... hermes --tui`.
3. **`/proc/<pid>/cmdline` cannot be the source.** Every Vivaldi window
   (the browser plus each PWA) reports the same pid and the generic
   `vivaldi-bin ... --restart`. Discord reports a versioned binary path. The
   command line alone cannot tell the apps apart or reproduce the right launch.
4. **Window class often does not match `StartupWMClass`.** The Teams `.desktop`
   entry says `StartupWMClass=crx__ompifgpmddkgmclendfeacglnodjjndh`, but the
   running Vivaldi window's class is
   `vivaldi-teams.cloud.microsoft__-Default`. A plain class lookup will miss
   some apps, so matching needs layers (below).
5. `omarchy-launch-or-focus` already shows how Omarchy matches a running window
   (class or title regex). We need the same check without the focus step, so we
   do not launch an app that is already running.

## Design

### 1. Launcher resolution (class → command)

Build a *launcher index* from three sources, in priority order:

1. **User overrides**, `~/.local/state/omarchy/global-workspaces/launchers.json`
   (the plugin's state directory, which survives plugin updates; the plugin's
   install folder does not). Hand-written `{ "<class>": "<command>" }`. Always
   wins. Setting a value to `null` hides that app from the login picker.
2. **Learned**, `~/.local/state/omarchy/global-workspaces/launchers-learned.json`, filled
   when we can match a window to a `.desktop` entry with confidence, so later
   sessions skip the fuzzy matching.
3. **`.desktop` scan**: for every `Application` entry, record `Name`, `Exec`
   (with `%u/%U/%f/%F` field codes removed), `StartupWMClass`, and the
   `.desktop` file id.

A window's class is matched to a `.desktop` entry in this order, stopping at the
first unambiguous hit:

1. exact `StartupWMClass`;
2. case-insensitive match of class to the `.desktop` file id or `Name`
   (covers `discord`, `foot`, and similar);
3. for Chromium-family PWAs (`vivaldi-<host>__-<profile>`,
   `chrome-<id>-<profile>`, `crx__<id>`): extract the host or extension id and
   match it against the URL or id in `Exec=` (the Teams case above);
4. otherwise **unresolved**: not relaunched, listed by `show-unresolved`.

Ambiguity (two `.desktop` entries match) is treated as unresolved, never guessed.

### 2. What the recording stores

Extend each `layout.json` entry with a `launcher` string, filled at snapshot
time from the index above. No process inspection. Entries without a launcher stay
placement-only, exactly as today.

### 3. Login picker, then launch

Nothing starts by itself. At login the user sees a picker listing the apps that
were open last session, every entry **selected by default**, with a **Launch**
button. The user deselects what they do not want this time and presses Launch.

Flow, run once per login from the existing `hyprland.start` hook:

1. After a short delay, wait until `hyprctl monitors` shows the recorded monitors
   (or a timeout passes), so placement has somewhere to put windows.
2. Build the list: one row per recorded window, `app name (monitor, slot)`, for
   every entry that has a resolved launcher. Rows for apps that are **already
   running** (started by autostart) are shown ticked-and-disabled as "running" and
   are never launched twice. Unresolved apps are listed greyed out with the reason,
   so nothing silently disappears.
3. Show the picker. Escape or "Skip" launches nothing.
4. On Launch, start the ticked rows one at a time, about 0.5 s apart, through
   `hyprctl dispatch hl.dsp.exec_cmd(...)` (never a shell with unquoted data).
   The existing `window.open` hook then moves each window to its recorded monitor
   and slot.
5. Remember the last selection only as a hint (rows the user unticked stay
   unticked next login? **open question 1**).

Single-instance apps (Discord, Vivaldi) ignore a second launch, so launches are
counted per class: `recorded - running`. Vivaldi's windows and PWAs launch through
their own `.desktop` entries, which is why the PWA host match in the resolver is
needed.

**Picker UI.** Two options, in order of preference:

- **A. Quickshell overlay in this plugin** (`overlay` plugin kind, `Overlay.qml`),
  summoned with `omarchy-shell shell summon <id>`. It matches Omarchy's look and
  can show per-row monitor and slot. It needs a second `kinds` entry and entry
  point in `manifest.json`, which `omarchy plugin validate` must accept, and it is
  the larger piece of work.
- **B. Terminal fallback**: a floating `foot` running `gum choose --no-limit
  --selected=...` (gum is already an Omarchy dependency), with Launch on Enter.
  Small, testable without a compositor, and the fallback when the shell is not
  running.

Proposal: build B first (it fixes the data flow and tests), then A as the polished
front end, both feeding the same `relaunch --apply <selection>` command.

### 4. Safety

- **Dry run**: `omarchy-gws-persist relaunch --dry-run` prints the list and the
  command for each row, and launches nothing. First thing to test live.
- The picker appears **only in Global Persisted mode** and **only once per login**
  (guarded by the `session-start` stamp), not after every config reload.
- A denylist hides apps that should never be offered: for example `win11-vm`
  (side effects), shells started by the user with arguments, and anything the user
  nulls out in `launchers.json`.
- Never kills or moves windows it did not open.

### 5. Menu surface

The plugin cannot add menu items, so the README gets an optional snippet for
`Trigger › Toggle › Workspace Mode › Relaunch picker now` (runs the picker on
demand, useful for testing without rebooting). The persisted mode itself needs no
new menu entry.

## Build order

1. **Resolver only**: `.desktop` scan plus class matching, with
   `omarchy-gws-persist launchers` printing a table of *window class → matched
   entry → command → confidence* for the windows open right now. No launching.
   Validate against real windows (Vivaldi PWAs, Discord, foot TUIs, Steam games).
2. **Record launcher** in snapshots; old `layout.json` entries without the field
   keep working.
3. **`relaunch --dry-run`** and **`relaunch --apply <selection>`** with the
   count rule, staggering and the denylist. No UI yet; selection is a list of ids.
4. **Terminal picker (option B)** feeding `--apply`; on-demand menu entry for
   testing.
5. **Wire into `hyprland.start`** in the Lua template: wait for monitors, show
   the picker once per login.
6. **Quickshell overlay picker (option A)**, if the terminal picker proves the
   flow.
7. README and menu snippet.

## Tests (no compositor)

- Fixture directory of `.desktop` files (Teams-style PWA, Discord, foot TUI,
  Steam game, an ambiguous pair) plus fixture window classes: each resolves to the
  expected entry or to "unresolved".
- `Exec=` field-code stripping and quoting.
- Relaunch count rule with a stub `hyprctl`: 2 recorded, 1 running, so exactly 1
  launch; none when all are running; none for unresolved or denied classes.
- Selection: all rows ticked by default; unticking a row means it is not launched;
  empty selection and Skip launch nothing.
- Already-running rows are shown as running and never launched.
- Dry run prints the plan and launches nothing.
- Override file wins, and `null` hides an app from the picker.
- Picker is offered once per login, and not in plain Global or Local mode.

## Open questions

1. Should next login remember what was unticked, or always start with everything
   ticked? You said default to all selected; proposed: always all ticked.
2. Steam games and VMs (`win11-vm`): offer them in the picker like any other app
   (ticked by default), or keep them on the denylist so they are never offered?
   Proposed: denylist, since launching them has side effects.
3. Terminals (`foot` with a working directory): offer in the picker, or skip in
   v1? Proposed: skip in v1.
4. Picker UI order: terminal picker first, Quickshell overlay second (proposed), or
   overlay straight away?
5. Should a user-extension `action` in `omarchy-menu.jsonc` count as a launcher
   source in v1, or only `.desktop` entries? Proposed: `.desktop` first.

## Known limits that remain

- Tiled window order inside a workspace still follows open order. This plan does
  not change that.
- Apps that restore their own windows (browsers with "reopen last session") may
  open more windows than recorded. The count rule limits launches, not what an app
  opens by itself.
