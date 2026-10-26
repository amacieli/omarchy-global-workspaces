# Plan: relaunch recorded apps in Global Persisted mode

Status: **plan only, no code written.** Today Global Persisted
(`bin/omarchy-gws-persist`) records where each app's window lives and puts the
window back when it opens, but it does not start anything. This plan covers
starting the apps too.

## Goal

At login, in Global Persisted mode, start the apps that were open last session,
so that the existing placement logic puts each window on its recorded monitor and
slot. The launch commands should come from what the Omarchy menu already points
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

1. **User overrides**, `~/.config/omarchy/global-workspaces/launchers.json`.
   Hand-written `{ "<class>": "<command>" }`. Always wins. Setting a value to
   `null` excludes that app from relaunch.
2. **Learned**, `~/.local/state/omarchy/global-workspaces/launchers.json`, filled
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

### 3. Relaunch at login

A new subcommand, `omarchy-gws-persist relaunch`, run once from the existing
`hyprland.start` hook, **after** monitors and persistent workspaces exist
(short delay, then verify `hyprctl monitors`).

For each recorded class with a launcher:

1. Count current windows of that class. Launch only the missing ones
   (`recorded count - running count`), so apps already started by autostart are
   not duplicated.
2. Launch via `hyprctl dispatch hl.dsp.exec_cmd(...)` or `setsid`, never through
   a shell with unquoted user data.
3. Stagger launches (about 0.5 s apart, tunable) and cap the total, so login
   does not stampede.
4. Do nothing further about placement. The existing `window.open` hook moves each
   window to its recorded monitor and slot.

Single-instance apps (Discord, Vivaldi) ignore a second launch, so the
count-based rule matters. Vivaldi's several windows and PWAs must be launched
through their own `.desktop` entries, which is why the PWA host match in step 3
of resolution is needed.

### 4. Controls and safety

- **Opt-in per app, default off for the first release.** `omarchy-global-workspaces
  relaunch list|enable <class>|disable <class>`. A blanket "relaunch everything I
  had open" is the second step, once the resolver is trusted.
- Denylist by default: shells and terminals started by the user with arguments,
  password managers, and anything unresolved.
- **Dry run first**: `omarchy-gws-persist relaunch --dry-run` prints what it
  would launch and why, and is the first thing to test live.
- Never relaunch while the grace window logic could be confused: relaunch runs
  once per login, guarded by the `session-start` stamp.
- Never kill or move windows it did not open.

### 5. Menu surface

Same pattern as the mode entries: the plugin cannot add menu items, so the README
gets a snippet for an optional `Trigger › Toggle › Workspace Mode › Relaunch
apps` entry that runs `relaunch enable/disable`. The decision is stored in
state, not in the menu file.

## Build order

1. **Resolver only**: `.desktop` scan plus class matching, with
   `omarchy-gws-persist launchers` printing a table of *window class → matched
   entry → command → confidence* for the windows open right now. No launching.
   Validate against real windows (Vivaldi PWAs, Discord, foot TUIs, Steam games).
2. **Record launcher** in snapshots; migration: old `layout.json` entries without
   the field keep working.
3. **`relaunch --dry-run`**, then `relaunch` with the count rule, staggering and
   the opt-in list.
4. **Wire into `hyprland.start`** in the Lua template, behind Global Persisted
   mode and the per-app opt-in.
5. README and menu snippet.

## Tests (no compositor)

- Fixture directory of `.desktop` files (Teams-style PWA, Discord, foot TUI,
  Steam game, an ambiguous pair) plus fixture window classes: each resolves to the
  expected entry or to "unresolved".
- `Exec=` field-code stripping and quoting.
- Relaunch count rule with a stub `hyprctl`: 2 recorded, 1 running, so exactly 1
  launch; none when all are running; none for unresolved or denied classes.
- Dry run prints the plan and launches nothing.
- Override file wins, and `null` excludes an app.

## Open questions

1. Should relaunch be opt-in per app (safer, proposed) or all-or-nothing at first?
2. Steam games and anything with side effects (VMs such as `win11-vm`): exclude by
   default? Proposed: yes, via the denylist.
3. Terminals (`foot` with a working directory): recreate the directory from the
   recorded `.desktop` or window title, or skip? Proposed: skip in v1.
4. Where should the user's override file live: under `~/.config/omarchy/` as
   above, or inside the plugin's state directory?
5. Should a user-extension `action` in `omarchy-menu.jsonc` count as a launcher
   source in v1, or only `.desktop` entries? Proposed: `.desktop` first, menu
   actions later.

## Known limits that remain

- Tiled window order inside a workspace still follows open order. This plan does
  not change that.
- Apps that restore their own windows (browsers with "reopen last session") may
  open more windows than recorded. The count rule limits launches, not what an app
  opens by itself.
