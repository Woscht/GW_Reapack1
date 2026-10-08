-- @description Project Time Tracker: Always-on deaktivieren
-- @version 2.2.3
-- @author audiocoder
-- @provides [main] .

-- Removes only the PTT block from Scripts/__startup.lua (does not stop a running tracker).

local function script_path()
  local info = debug.getinfo(1, "S").source:match("^@(.+)$")
  return info:match("^(.*[/\\])")
end

local root = script_path()
PTT = { _script_root = root, VERSION = "2.2.3" }
dofile(root .. "modules/startup_on.lua")

local resource = reaper.GetResourcePath and reaper.GetResourcePath() or ""
local ok, reason = PTT.startup_on.disable({ resource_path = resource })

if not ok then
  reaper.ShowConsoleMsg("[PTT] Always-on deaktivieren fehlgeschlagen: " .. tostring(reason) .. "\n")
  return
end

local startup = PTT.startup_on.startup_file(resource)
if reason == "absent" then
  reaper.ShowConsoleMsg("[PTT] Always-on war nicht gesetzt (" .. tostring(startup) .. ").\n")
else
  reaper.ShowConsoleMsg("[PTT] Always-on deaktiviert: " .. tostring(startup) .. "\n")
  reaper.ShowConsoleMsg("[PTT] Nach REAPER-Neustart startet der Tracker nicht mehr automatisch.\n")
end
