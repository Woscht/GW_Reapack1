-- @description ProjectTimeTracker
-- @author audiocoder
-- @version 2.1.2
-- @changelog
--   + macOS SMB /Volumes/PRODUKTION paths for central mirror
-- @provides
--   [main] .
--   ProjectTimeTracker_Stop.lua
--   [nomain] modules/*.lua

-- ProjectTimeTracker.lua — entry: load modules and start bootstrap

local function script_path()
  local info = debug.getinfo(1, "S").source:match("^@(.+)$")
  return info:match("^(.*[/\\])")
end

local root = script_path()
PTT = { _script_root = root, VERSION = "2.1.2" }

local mods = {
  "util",
  "activity",
  "session_wall",
  "session_rec",
  "writer",
  "crash",
  "report",
  "path_migrate",
  "untitled",
  "identity",
  "sync_hook",
  "config",
  "mirror",
  "bootstrap",
}

for _, m in ipairs(mods) do
  dofile(root .. "modules/" .. m .. ".lua")
end

PTT.bootstrap.run(reaper)
