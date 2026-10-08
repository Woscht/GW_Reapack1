-- @description Project Time Tracker: Always-on aktivieren
-- @version 2.2.3
-- @author audiocoder
-- @provides [main] .

-- Writes a marked block into Scripts/__startup.lua and starts the tracker now.

local function script_path()
  local info = debug.getinfo(1, "S").source:match("^@(.+)$")
  return info:match("^(.*[/\\])")
end

local root = script_path()
PTT = { _script_root = root, VERSION = "2.2.3" }
dofile(root .. "modules/startup_on.lua")

local resource = reaper.GetResourcePath and reaper.GetResourcePath() or ""
local ptt_main = root .. "ProjectTimeTracker.lua"
local ok, reason = PTT.startup_on.enable({
  resource_path = resource,
  ptt_path = ptt_main,
})

if not ok then
  reaper.ShowConsoleMsg("[PTT] Always-on aktivieren fehlgeschlagen: " .. tostring(reason) .. "\n")
  return
end

local startup = PTT.startup_on.startup_file(resource)
if reason == "already" then
  reaper.ShowConsoleMsg("[PTT] Always-on war bereits aktiv: " .. tostring(startup) .. "\n")
else
  reaper.ShowConsoleMsg("[PTT] Always-on aktiviert: " .. tostring(startup) .. "\n")
  reaper.ShowConsoleMsg("[PTT] Ab dem nächsten REAPER-Start läuft der Tracker automatisch.\n")
end

-- Start tracker in this session if not already running.
local running = reaper.GetExtState("ProjectTimeTracker", "running")
if running ~= "1" then
  local f = io.open(ptt_main, "r")
  if f then
    f:close()
    dofile(ptt_main)
    reaper.ShowConsoleMsg("[PTT] Tracker in dieser Session gestartet.\n")
  else
    reaper.ShowConsoleMsg("[PTT] ProjectTimeTracker.lua nicht gefunden: " .. ptt_main .. "\n")
  end
else
  reaper.ShowConsoleMsg("[PTT] Tracker läuft bereits.\n")
end
