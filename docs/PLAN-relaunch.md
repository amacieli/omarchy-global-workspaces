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

## Decisions so far

1. **Every row starts ticked each login** (except side-effect apps, decision 2).
   The picker has no memory of earlier *selections*; what persists is dismissal
   (decision 6).
2. **Side-effect apps start unticked.** Steam games and VMs (for example
   `win11-vm`) are shown in the picker but deselected by default; the user ticks
   them if wanted.
3. **foot terminals are kept.** They are offered like any other app (see "Terminals"
   below for what is and is not restored).
4. **Only apps referenced by the Omarchy menu take part, in every respect.** An
   app started by hand from a terminal, with no `.desktop` entry and no menu
   action pointing at it, is not recorded, not placed, not offered and not
   launched. (This narrows what the recorder does today; see build order.)
5. **The picker appears once per login, and only while Global Persisted is the
   selected mode.** Records must survive any period spent in Local or plain Global
   mode (next section).
6. **Anything not ticked when Launch is pressed is dismissed for good.** Its record
   is deleted, so it no longer appears in the picker (or is placed) at later
   logins. It comes back only if you launch it yourself later, because the recorder
   then records it again like any newly seen app. This applies equally to a row you
   unticked and to a row that started unticked (Steam games, VMs): a Steam game or
   VM you leave unticked is dismissed, and returns, unticked again, once you have
   launched it by hand. Skip or Escape dismisses nothing. For an app with several
   windows (two Vivaldi windows), dismissal removes only the rows left unticked.
7. **The picker is built from Omarchy's own menu** (`omarchy-menu-select`), not a
   separate tool.

## Records survive other modes

Requirement: logging in even once while Global Persisted is *not* selected must
not lose any app or window record. The user would otherwise start from scratch.

How the design guarantees it:

- **Nothing runs outside persisted mode.** The Lua hooks that record, place and
  show the picker are only registered when the persisted flag exists at config
  load. In Local or Global mode no code touches `layout.json`, so logins there
  leave it byte-for-byte unchanged. (The recorder is already a no-op without the
  flag; the picker and relaunch will follow the same rule.)
- **Switching modes never deletes records.** `on`, `off` and `persisted` leave
  `layout.json` and the launcher index alone. Wiping records is a separate,
  explicit command (`omarchy-global-workspaces forget`), never a side effect.
- **No automatic pruning.** Today the recorder drops entries unseen for 30 days of
  wall-clock time. After a long stretch in another mode, the first persisted
  snapshot would erase everything not currently open. Since the user now dismisses
  apps explicitly (decision 6), that timer is not needed and is **removed
  entirely**: a record is deleted only by an untick-and-Launch, by `forget`, or
  because its class stopped resolving to a menu entry (decision 4). **This changes
  existing code; it is step 0 of the build order.**
- **One-deep backup.** Before the first write of each persisted login, copy
  `layout.json` to `layout.json.bak`, so a bug or a bad login can be undone by hand.
- **Records go stale, not missing, while away.** Apps opened or moved during
  Local/Global mode are not recorded. Re-enabling Persisted resumes from the last
  persisted state and updates it as windows open.

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
4. otherwise **unresolved**: excluded from relaunch (decision 4). They are listed
   only by `omarchy-gws-persist launchers --unresolved`, for debugging.

Ambiguity (two `.desktop` entries match) is treated as unresolved, never guessed.
An app launched by hand from a terminal normally has no `.desktop` entry or menu
action, so it falls out here with no special handling.

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
   every entry that resolves to a menu-referenced launcher. Rows for apps that are
   **already running** (started by autostart) are shown as "running" and are never
   launched twice. Apps with no menu-referenced launcher are not listed at all
   (decision 4). Side-effect apps (Steam games, VMs) are listed but **unticked**
   (decision 2); everything else is ticked.
3. Show the picker. Escape or "Skip" launches nothing.
4. On Launch, start the ticked rows one at a time, about 0.5 s apart, through
   `hyprctl dispatch hl.dsp.exec_cmd(...)` (never a shell with unquoted data).
   The existing `window.open` hook then moves each window to its recorded monitor
   and slot.
5. On Launch, ticked rows are started and every other row is dismissed: its record
   is deleted (decision 6), whether the user unticked it or it started unticked
   (Steam, VMs). Skip and Escape change nothing.

Single-instance apps (Discord, Vivaldi) ignore a second launch, so launches are
counted per class: `recorded - running`. Vivaldi's windows and PWAs launch through
their own `.desktop` entries, which is why the PWA host match in the resolver is
needed.

**Picker UI: Omarchy's own menu.** Omarchy ships `omarchy menu select`
(`omarchy-menu-select <prompt> [option...]`), a single-choice menu in the shell's
own look, where an option may carry an icon glyph and a subtext. It has no
multi-select, so the checklist is a loop around it:

1. Show one row per app: a tick glyph (`☑`/`☐`) plus the app name, with the
   monitor and slot as subtext, and two extra rows, **Launch** and **Skip**.
2. Choosing an app row flips its tick and shows the menu again; choosing **Launch**
   starts the ticked apps; **Skip** or Escape launches nothing.
3. The loop state is a plain list in a temporary file, so the menu code stays a thin
   wrapper over `relaunch --apply <ids>`.

Consequence to accept: each toggle closes and reopens the menu (a flicker). If
that proves annoying, the menu's provider mechanism (`provider: "name"` returning
JSON rows with `checked`) could allow an in-place checklist, but that needs a
spike first and is not assumed. A custom Quickshell overlay and a gum-based picker
are dropped from the plan, since the menu already exists.

### Terminals

foot windows are kept in the picker. They resolve to a menu entry in two ways: a
dedicated one such as the Hermes TUI (`foot --app-id=TUI.tile ... hermes --tui`),
and the plain `foot.desktop`. What is restored is what the menu entry launches: the
Hermes TUI comes back as itself; a plain foot comes back as a fresh terminal in the
default directory, **not** in the directory it had. A foot running something the
menu does not know about (an ad-hoc command, a particular `--working-directory`)
is excluded by decision 4. Restoring working directories would need recording
`/proc/<pid>/cwd` and is out of scope for v1.

### 4. Safety

- **Dry run**: `omarchy-gws-persist relaunch --dry-run` prints the list and the
  command for each row, and launches nothing. First thing to test live.
- The picker appears **only in Global Persisted mode** and **only once per login**
  (guarded by the `session-start` stamp), not after every config reload.
- **Default-unticked list** for apps with side effects: Steam launches
  (`steam steam://...`), VM launchers (`win11-vm`, anything calling `VBoxManage` or
  `virt-manager`), plus whatever the user adds in `launchers.json`. These appear in
  the picker, deselected. A `null` value in `launchers.json` hides an app from the
  picker completely.
- Never kills or moves windows it did not open.

### 5. Menu surface

The plugin cannot add menu items, so the README gets an optional snippet for
`Trigger › Toggle › Workspace Mode › Relaunch picker now` (runs the picker on
demand, useful for testing without rebooting). The persisted mode itself needs no
new menu entry.

## Build order

0. **Make records safe across modes** (existing recorder): remove the 30-day
   wall-clock prune, add `layout.json.bak`, add `omarchy-global-workspaces forget
   [class]`, and add tests proving `layout.json` is unchanged by logins in
   Local/Global mode and by mode switches.
1. **Resolver only**: `.desktop` scan plus class matching, with
   `omarchy-gws-persist launchers` printing a table of *window class → matched
   entry → command → confidence* for the windows open right now. No launching.
   Validate against real windows (Vivaldi PWAs, Discord, foot TUIs, Steam games).
2. **Record launcher and restrict the recorder to menu-referenced apps**
   (decision 4): snapshots store each window's resolved launcher, and classes that
   do not resolve are no longer recorded or placed. The first filtered snapshot
   removes records of unresolved classes already in `layout.json`; these are the
   only records dropped by a rule rather than by the user (untick-and-Launch or
   `forget`).
   Old entries without the field keep working until their class resolves.
3. **`relaunch --dry-run`** and **`relaunch --apply <selection>`** with the
   count rule, staggering and the default-unticked list. No UI yet; selection is a list of ids.
4. **Menu picker** (`omarchy-menu-select` loop) feeding `--apply`; plus an
   on-demand menu entry to run it without rebooting, for testing.
5. **Wire into `hyprland.start`** in the Lua template: wait for monitors, show
   the picker once per login, persisted mode only.
6. README and menu snippet.

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
- Records survive: with persisted mode off, simulate several logins and mode
  switches and assert `layout.json` is byte-identical; after 100 days of fake wall
  time in another mode, the first persisted snapshot prunes nothing; no code path
  removes a record by age.
- Side-effect apps (Steam, VM) are listed unticked; ordinary apps are listed ticked;
  every selection starts from those defaults regardless of the previous login.
- A class with no `.desktop` entry or menu action is not listed, not recorded and
  not placed; its old record disappears at the first filtered snapshot.
- On Launch, each row left unticked has its record deleted, including rows that
  started unticked (Steam, VM); exactly those records go (one window of a
  multi-window class leaves the others); the next login does not list them;
  launching the app by hand and letting the recorder see it brings it back (and a
  Steam or VM row is again unticked by default).
- Skip and Escape delete nothing.
- The menu loop: toggling flips a tick, Launch returns the ticked ids, Skip and
  Escape return none (with `omarchy-menu-select` stubbed).
- Records are removed only by untick-and-Launch, `forget`, or an unresolvable class.

## Open questions

1. **Menu flicker.** `omarchy menu select` shows a list and returns the one row you
   pick, then closes. It cannot hold several ticks at once. So each time you tick or
   untick a row, the menu closes and is shown again with the new tick state, which
   looks like a brief blink. Proposed: accept that for v1, because it works with the
   menu as it is and needs nothing from Omarchy. If it proves annoying, a later spike
   can try the menu's `provider` mechanism, which may allow an in-place checklist.
   No decision needed unless you would rather spike first.

## Known limits that remain

- Tiled window order inside a workspace still follows open order. This plan does
  not change that.
- Apps that restore their own windows (browsers with "reopen last session") may
  open more windows than recorded. The count rule limits launches, not what an app
  opens by itself.
