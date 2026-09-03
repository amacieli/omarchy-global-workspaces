-- Global workspace mode — active when this file is loaded by toggles.lua.
-- When present in ~/.local/state/omarchy/toggles/hypr/, global mode is ON.
--
-- Each monitor owns an exclusive workspace range (offset = monitor_id * 10):
--   monitor id 0  →  workspaces  1-10
--   monitor id 1  →  workspaces 11-20
--   monitor id 2  →  workspaces 21-30
--
-- Workspaces are created ON DEMAND by omarchy-hyprland-workspace-global-switch
-- when the user first switches to a slot. This file deliberately does NOT
-- pre-create the full 30-workspace grid via persistent workspace_rules — doing
-- so causes all 30 workspaces to linger in Hyprland's workspace list even when
-- empty, cluttering the session. On-demand creation keeps the workspace list
-- clean (only visited slots appear).
--
-- The only work done here is storing the sorted monitor list for use by
-- tiling.lua at config-load time.

local monitors = hl.get_monitors()

-- Sort monitors by Hyprland id (ascending) for deterministic offset assignment.
table.sort(monitors, function(a, b) return a.id < b.id end)

-- Store sorted monitor list as a global so other config modules can read it
-- without re-querying. Evaluated once per hyprctl reload.
_G.omarchy_global_ws_monitors = {}
for _, mon in ipairs(monitors) do
  table.insert(_G.omarchy_global_ws_monitors, { id = mon.id, name = mon.name })
end
