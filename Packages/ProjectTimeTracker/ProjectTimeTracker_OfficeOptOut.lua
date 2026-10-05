-- @description Project Time Tracker: Toggle Nicht ins Büro
-- @version 2.1.8
-- @author audiocoder
-- @provides [main] .

-- Opt out of central mirror + notes auto-open for this saved project.
-- Local timelog continues. Toggle again to re-enable office sync.

local function script_path()
  local info = debug.getinfo(1, "S").source:match("^@(.+)$")
  return info:match("^(.*[/\\])")
end

local root = script_path()
PTT = { _script_root = root, VERSION = "2.1.8" }
dofile(root .. "modules/office_opt.lua")

local _, fn = reaper.EnumProjects(-1, "")
if not fn or fn == "" then
  reaper.ShowConsoleMsg(
    "[PTT] Nicht ins Büro: bitte zuerst speichern (Untitled hat keinen Office-Spiegel).\n")
  return
end

local opted = PTT.office_opt.toggle(reaper)
if opted then
  reaper.ShowConsoleMsg(
    "[PTT] Nicht ins Büro: AN — kein Mirror, keine Notes-Erinnerung (nur lokal).\n")
else
  reaper.ShowConsoleMsg(
    "[PTT] Nicht ins Büro: AUS — Mirror/Notes wieder wie konfiguriert.\n")
end
