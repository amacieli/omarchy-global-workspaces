# Omarchy-Global-Workspaces PR Feedback Analysis

## Executive Summary

You've identified three real issues and received one additional critical bug report from the reviewer. Here's the breakdown:

1. **Issue 1 (Critical)**: Monitor ID instability breaks workspace persistence across hotplug
2. **Issue 2 (Code Quality)**: Duplicate offset formula in Lua and QML — QML can be made independent
3. **Issue 3 (Real Bug)**: Stale `activeWorkspace` property in Quickshell affects focus state display
4. **Issue 4 (Critical Logic)**: `awIsFocused()` hardcodes monitor 0, breaks when panel is off/clamshell
5. **Bonus Issue 5 (Gotcha)**: `ipairs()` hangs in Hyprland config under certain menu contexts

---

## ISSUE 1: Monitor ID Instability (Critical — Data Loss Risk)

### What the Current Code Does

```lua
-- hypr/toggles/workspace-global.lua
offset = monitor.id * 10
workspace_id = offset + slot  -- e.g., slot 2 on monitor id=1 → WS12
```

### What Breaks and Why

**Scenario: Hotplug an external monitor**

Starting state:
- Monitor 0 (internal panel): id=0, owns WS1-10
- Monitor 1 (external HDMI): id=1, owns WS11-20
- User has windows on external monitor, workspace WS12-15 occupied

Then:
1. User unplugs external monitor
2. Hyprland reassigns remaining monitor ids: `{0, 1}` → `{0, 2}`  (this is Hyprland issue #2601)
3. User plugs a different external monitor in
4. Hyprland assigns it id=1 (first available)

**Result: Workspace orphaning**
- New monitor 1 now owns WS11-20 (the range previously orphaned when you unplugged)
- Original workspaces (WS12-15 with your windows) are now "owned" by monitor id=2
- Monitor 2 never existed when you created those windows
- Workspaces are silently moved to a new, unbounded, ever-growing range
- **Each hotplug cycle leaks workspace ownership** — over time you accumulate orphaned workspaces with no assigned monitor

**Root cause**: Hyprland ID assignment is transient (next-available), not stable. There is no concept of "same physical monitor, different ID."

### Why This Is Worse Than It Looks

- **Persistence assumption broken**: Your feature stores window layouts implicitly in Hyprland workspace IDs. Hotplug changes the IDs without updating the implicit mapping.
- **No recovery path**: Once workspaces orphan, they're not re-associated with the monitor that created them. Users can't find their windows.
- **Grows unbounded**: Every hotplug cycle increments monitor ids, leading to WS30, WS40, WS50 workspace IDs over time.

### Proposed Solution

Use **stable monitor identity** (name or description) instead of transient IDs for offset assignment.

**Mechanism:**

```json
// ~/.local/state/omarchy/monitor-bases.json
{
  "eDP-1": {"base": 0, "width": 1920, "height": 1200},
  "HDMI-1": {"base": 10, "layout": "right"},
  "DP-2": {"base": 20}
}
```

On **first plugin** of a monitor name (e.g., "HDMI-1"):
- Auto-assign next free base: 10, 20, 30, ...
- Store persistently with the monitor's current properties
- Use this base forever, regardless of Hyprland's id assignment

On **hotplug/unplug/replug**:
- Hyprland assigns new id=N to monitor named "HDMI-1"
- Look up "HDMI-1" in monitor-bases.json → base=10
- Use base=10 + slot, completely ignoring the new Hyprland id
- Workspaces WS11-20 are now correctly associated with the HDMI monitor again

**How it works:**
- First time: 3 monitors → bases {0, 10, 20}
- Unplug monitor 1, replug monitor 2: still 2 monitors, still use {0, 20} (monitor 1 orphaned but not lost)
- Plug original monitor 1 back: immediately reuse base 10

### Implementation Details

**Lua side** (`hypr/toggles/workspace-global.lua`):
```lua
local function load_monitor_bases()
  -- Read ~/.local/state/omarchy/monitor-bases.json
  -- Return { name → base } mapping
  -- Fill missing entries, auto-assign new bases
  -- Persist back to JSON
end

_G.omarchy_monitor_base_map = load_monitor_bases()
```

**QML side** (`shell/Workspaces.qml`):
```qml
function monitorBase(name) {
  // read base from monitor-bases.json via IPC or file watch
  // fallback to name-based hash if json not available
  // never use monitorId * 10 in the offset calculation
}

readonly property int thisMonitorOffset: {
  var base = monitorBase(root.thisMonitorName)
  return base  // not monitorId * 10
}
```

**Reference implementation**: `shezdy/hyprsplit` does this with `monitor_priority()` — sorts monitors by stable key and assigns priority/base on first load.

### Implementation Priority

**HIGH** — Do this first. It's a correctness issue, not a performance issue. Everything else depends on monitors having stable identity.

---

## ISSUE 2: Offset Formula Duplication in QML (Design Issue)

### What the Current Code Does

```qml
// shell/Workspaces.qml — lines 81, 147, 176
readonly property int thisMonitorOffset: root.thisMonitorId * 10
var wsId = mons[m].id * 10 + slot  // line 147
```

Formula is hardcoded in two places in QML, must match the Lua `offset = monitor.id * 10`.

### What Breaks

Nothing right now, but:
- If you change the offset scheme (Issue 1 fixes this), you must edit QML **and** Lua
- Any mismatch silently breaks the feature
- The QML code duplicates a "business rule" it shouldn't know about

### Why This Is a Problem

Quickshell already exposes the monitor-workspace relationship directly:
```qml
HyprlandMonitor.activeWorkspace  // which workspace is this monitor on?
HyprlandWorkspace.monitor        // which monitor owns this workspace?
```

You can derive the slot from raw workspace data without using the offset formula:
```qml
function getSlotForWorkspaceId(wsId, monitorName) {
  var base = getMonitorBase(monitorName)  // from monitor-bases.json (Issue 1)
  return wsId - base
}
```

### Proposed Solution

**Remove the offset formula from QML entirely.** Let QML operate on raw Hyprland data and derive everything through Quickshell's built-in mappings.

**Current code** (lines 134-156):
```qml
function awIsOccupied(slot) {
  if (!root.globalMode) {
    // ... local mode ...
  }
  // Global mode: walk all monitors, check WS(monitorId*10 + slot)
  var mons = Hyprland.monitors.values
  for (var m = 0; m < mons.length; m++) {
    var wsId = mons[m].id * 10 + slot  // ← HARDCODED FORMULA
    var wsList = Hyprland.workspaces.values
    for (var w = 0; w < wsList.length; w++) {
      if (wsList[w].id === wsId && wsList[w].toplevels.values.length > 0) {
        return true
      }
    }
  }
  return false
}
```

**Proposed replacement**:
```qml
function awIsOccupied(slot) {
  if (!root.globalMode) {
    // ... local mode ...
  }
  // Global mode: filter all workspaces by monitor, find any on this slot
  var wsList = Hyprland.workspaces.values
  for (var w = 0; w < wsList.length; w++) {
    var ws = wsList[w]
    // Get the base for this workspace's monitor
    var base = getMonitorBase(ws.monitor.name)
    var wsSlot = ws.id - base
    if (wsSlot === slot && ws.toplevels.values.length > 0) {
      return true
    }
  }
  return false
}
```

**Advantages:**
- No duplicate formula in QML
- When you fix Issue 1 (add stable bases), only Lua changes
- Closer to Quickshell's actual data model (workspaces track their monitor directly)
- Easier to debug: you see "WS12 belongs to monitor HDMI-1, base=10, slot=2" not "does 12 equal 1*10+2?"

### Implementation Priority

**MEDIUM** — Do this after Issue 1, because Issue 1 changes how bases are assigned anyway. Combined, you're updating the formula in only one place (Lua) and making QML data-driven.

---

## ISSUE 3: Stale `activeWorkspace` Property (Real Quickshell Bug)

### What the Current Code Does

```qml
// shell/Workspaces.qml — line 120
var activeWsId = mons[i].activeWorkspace ? mons[i].activeWorkspace.id : -1
```

This reads `HyprlandMonitor.activeWorkspace` to determine which slot is focused.

### What Breaks

**Scenario: Multi-monitor synchronized switch**

1. User presses SUPER+2
2. Script switches all monitors to their slot-2 workspace
3. Monitor A (focused) receives IPC event, updates its activeWorkspace
4. Monitor B (not focused) also switched, **but doesn't receive an IPC event**
5. In QML on monitor B's bar:
   - `Hyprland.workspaces.values` shows the window data correctly (monitor B sees the new windows)
   - `monitor B.activeWorkspace` still shows the old workspace (not updated)
   - Result: Monitor B's bar shows slot 1 as focused, even though the windows are on slot 2

**Root cause**: Quickshell's IPC listener only updates `activeWorkspace` when Hyprland emits an IPC event *for that monitor*. If a workspace switch happens via Lua dispatch without keyboard focus on that monitor, no event fires.

**Proof**: User reports "Hovering the cursor over that monitor 'fixes' it" — hovering generates IPC events, forcing a refresh.

### Why This Matters

- **Inconsistent UX**: Bars show different focused slot even though all monitors are on the same slot
- **Confusing focus indicator**: Users can't trust the highlight
- **Not a code bug in your feature** — it's a Quickshell limitation. But your feature exposes it.

### Proposed Solution

Add a manual refresh after every synchronized switch:

```bash
# After omarchy-hyprland-workspace-global-switch completes:
omarchy-shell -q "$target_bar" "refresh"  # Tells bar to call Hyprland.refreshMonitors() + refreshWorkspaces()
```

**Lua entry point** (bindings-global-workspaces.lua):
```lua
o.bind("SUPER + 1", "Switch to AW 1", function()
  os.execute("omarchy-hyprland-workspace-global-switch 1 &")
  -- Fire refresh on all bars, backgrounded to avoid blocking keybind
  os.execute("omarchy-shell -q '*' refresh &")
end)
```

**QML side** (shell/Workspaces.qml):
```qml
function handleRefreshCommand() {
  Hyprland.refreshMonitors()
  Hyprland.refreshWorkspaces()
}
```

Or via IpcHandler:
```qml
IpcHandler {
  id: refreshHandler
  onMessageReceived: function(message) {
    if (message === "refresh") {
      Hyprland.refreshMonitors()
      Hyprland.refreshWorkspaces()
    }
  }
}
```

**Why this works**: Forces a full re-query of Hyprland state, bypassing the stale event-driven update.

**Trade-offs**:
- Adds a small network call after every switch (negligible latency, backgrounded)
- Fixes a real bug affecting user experience
- Is a workaround, not a fix — the real fix is in Quickshell (improve its IPC event coverage)

### Implementation Priority

**MEDIUM-HIGH** — This affects UX on every workspace switch. Do it after Issue 1, but before Issue 4 is critical.

---

## ISSUE 4: `awIsFocused()` Hardcodes Monitor 0 (Critical Logic Bug)

### What the Current Code Does

```qml
// shell/Workspaces.qml — lines 111-126
function awIsFocused(slot) {
  if (!root.globalMode) return ...
  
  // Read monitor 0's active workspace id — that equals the current AW slot.
  var mons = Hyprland.monitors.values
  for (var i = 0; i < mons.length; i++) {
    if (mons[i].id === 0) {  // ← HARDCODED ASSUMPTION
      var activeWsId = mons[i].activeWorkspace ? mons[i].activeWorkspace.id : -1
      return activeWsId === slot
    }
  }
  return false
}
```

**Assumption**: Monitor 0 exists, is always present, and is the authoritative source for the current slot.

### What Breaks

**Scenario 1: Clamshell mode** (internal panel off)
- User docks laptop, disables internal panel
- Hyprland no longer reports monitor 0 (it's unplugged)
- `awIsFocused()` never finds monitor 0, always returns false
- Result: All bars show no focused slot, even though the switch worked

**Scenario 2: Multi-monitor dock without internal panel**
- External dock only, no integrated monitor
- Hyprland has monitors 1, 2, 3 (no 0)
- Again, returns false for all slots

**Scenario 3: Internal panel gets reassigned (rare)**
- Some setups reassign monitor IDs on profile change
- Panel becomes id=1, external becomes id=0
- Using monitor 0 as reference now reads the external monitor

### Root Cause

The code assumes "all monitors switch together means monitor 0 always knows the current slot." This is true if monitor 0 always exists and is always on the active workspace. But Hyprland doesn't guarantee this.

### Why This Is Worse Than It Looks

**For users**: Bars become completely non-functional in clamshell mode. The feature works (windows move correctly), but the UI shows no focused slot.

**For code maintenance**: Adding a fourth monitor or changing dock configs silently breaks focus detection.

### Proposed Solution

**Use any connected monitor's active workspace**, normalized by its base:

```qml
function awIsFocused(slot) {
  if (!root.globalMode) {
    return Hyprland.focusedWorkspace !== null &&
           Hyprland.focusedWorkspace.id === slot
  }
  
  // Global mode: find the current slot from ANY monitor's active workspace.
  // All monitors are on the same slot, so any monitor works.
  var mons = Hyprland.monitors.values
  for (var m = 0; m < mons.length; m++) {
    var mon = mons[m]
    if (mon.activeWorkspace !== null) {
      var base = getMonitorBase(mon.name)
      var currentSlot = mon.activeWorkspace.id - base
      // All monitors should be on the same slot in global mode
      return currentSlot === slot
    }
  }
  return false  // No connected monitors (shouldn't happen)
}
```

**Why this works:**
- If monitor 0 exists and is on slot 2, reading it gives slot=2
- If monitor 0 is gone and monitor 1 is on slot 2, reading it gives 12 - 10 = 2
- All bars read the same slot because all monitors are on the same slot in global mode
- Falls back gracefully to any connected monitor

**Key insight**: In global mode, all monitors are synchronized, so it doesn't matter which monitor you read — they should all report the same slot. The code was over-specifying (reading only monitor 0) when it should generalize (read any connected monitor).

### Implementation Priority

**CRITICAL** — Do this in parallel with Issue 1. Both are correctness issues. This one is easier (3-line change) but breaks clamshell mode.

---

## ISSUE 5: `ipairs()` Hangs in Hyprland Config (Lua Gotcha)

### What Breaks

```lua
-- hypr/toggles/workspace-global.lua — line 27
for _, mon in ipairs(monitors) do
  table.insert(_G.omarchy_global_ws_monitors, {id = mon.id, name = mon.name})
end
```

**Scenario**: User opens Omarchy menu, which calls `omarchy-menu-keybindings`.

`omarchy-menu-keybindings` evaluates the Hyprland config (`~/.config/hypr/hyprland.conf`) under a **stub** Hyprland object where every property returns a truthy sentinel.

```lua
-- Simplified stub behavior
_ENV.hl = setmetatable({}, {
  __index = function(t, k)
    return true  -- or a sentinel function
  end
})

-- Now calling hl.get_monitors() in that stub context
-- returns the sentinel, not an actual table
-- ipairs() on a non-table returns 0 iterations and never terminates
```

Result: `omarchy-menu-keybindings` hangs forever because it tries to iterate over a sentinel, not a table.

### Why This Happens

`omarchy-menu-keybindings` uses a stub to extract metadata without actually running the full Hyprland config. The stub's `__index` is too permissive — it returns true for everything, including `hl.get_monitors()`.

This affects **any code using `ipairs()` on a Hyprland API result** in that context, not just this feature. `shezdy/hyprsplit` has the same issue.

### Solution

Replace `ipairs()` with a numeric for loop:

```lua
-- hypr/toggles/workspace-global.lua
local monitors = hl.get_monitors()

-- BAD: hangs under menu stub
-- for _, mon in ipairs(monitors) do ... end

-- GOOD: numeric for works even if monitors is a sentinel
for i = 1, #monitors do
  local mon = monitors[i]
  table.insert(_G.omarchy_global_ws_monitors, {id = mon.id, name = mon.name})
end
```

**Why this works**: The `#` operator evaluates the sentinel's metatable for length, which either returns 0 (loop doesn't run) or triggers the sentinel correctly. Numeric `for` doesn't depend on `__index` returning a real iterator.

### Implementation Priority

**LOW-MEDIUM** — This is a bug, but only affects the Omarchy menu. Keybinds work fine. Fix it while doing Issue 1, since you're touching that file anyway.

---

## Implementation Order & Dependencies

### Dependency Graph

```
Issue 1 (Stable bases)
  ↓
  ├─ Issue 2 (Remove QML formula duplication) — depends on Issue 1 base mapping
  ├─ Issue 4 (Fix awIsFocused) — depends on Issue 1 base mapping
  └─ Issue 5 (Fix ipairs) — no dependencies

Issue 3 (Stale activeWorkspace) — independent, can be done in parallel
```

### Recommended Order

1. **Issue 1** (1-2 hours): Implement stable monitor-bases.json and Lua mapping
   - Unlocks Issues 2 and 4
   - Is the correctness foundation

2. **Issue 4** (15 minutes): Fix `awIsFocused()` to use any monitor
   - Small change, high impact (fixes clamshell mode)
   - Depends on Issue 1 base mapping

3. **Issue 2** (30 minutes): Refactor QML to remove formula duplication
   - Now safe because Issue 1 defines how bases work
   - Makes QML code data-driven

4. **Issue 3** (15 minutes): Add refresh after synchronized switches
   - Independent, but improves UX on every switch
   - Can be done in parallel with Issues 1-2

5. **Issue 5** (5 minutes): Replace `ipairs()` with numeric for
   - While editing workspace-global.lua for Issue 1

### Time Estimate

- Issue 1: 60-90 minutes (file structure, Lua JSON parsing, auto-assignment logic)
- Issue 4: 10-15 minutes (3-line change, test clamshell mode)
- Issue 2: 20-30 minutes (refactor awIsOccupied, awIsFocused)
- Issue 3: 10-15 minutes (add IpcHandler, fire refresh after switches)
- Issue 5: 2-5 minutes (replace `ipairs` with `for i = 1, #mons`)

**Total: ~2 hours** for a fully robust implementation.

---

## What @Chessing234's Comment Means

> "global sync looks fine, but awIsFocused shouldn't hardcode monitor 0 — if that output is gone every bar shows no focused workspace while switches still work. derive the slot from any connected monitor's active workspace minus its offset."

Translation: **Issue 4** — the hardcoding breaks when monitor 0 doesn't exist. The fix is to generalize the lookup. This is exactly what we've described above.

---

## Summary of Changes Required

| File | Change | Why |
|------|--------|-----|
| New: `~/.local/state/omarchy/monitor-bases.json` | Store stable monitor→base mapping | Issue 1 |
| `hypr/toggles/workspace-global.lua` | Load/update monitor-bases.json; export mapping; fix `ipairs()` | Issues 1, 5 |
| `hypr/bindings-global-workspaces.lua` | Fire refresh after every switch | Issue 3 |
| `shell/Workspaces.qml` | Remove offset formula duplication; use `getMonitorBase()` lookup; fix `awIsFocused()` to use any monitor; add IpcHandler for refresh | Issues 2, 3, 4 |

---

## Testing Checklist

- [ ] **Issue 1**: Unplug/replug external monitor 3 times, verify workspaces stay on correct monitor
- [ ] **Issue 4**: Disable internal panel, verify bars still show focused slot (clamshell mode)
- [ ] **Issue 2**: Verify switching to different slot still works after refactoring
- [ ] **Issue 3**: Multi-monitor switch, check all bars highlight the same slot (watch during transition)
- [ ] **Issue 5**: Open Omarchy menu, verify it doesn't hang
