-- @description Project Time Tracker: Open notes UI
-- @version 2.1.11
-- @author audiocoder
-- @provides [main] .

-- Manual action: always open DispoDisco notes page for the current project.

local function script_path()
  local info = debug.getinfo(1, "S").source:match("^@(.+)$")
  return info:match("^(.*[/\\])")
end

local root = script_path()
PTT = { _script_root = root, VERSION = "2.1.11" }

local mods = {
  "util",
  "config",
  "notes_ui",
}

for _, m in ipairs(mods) do
  dofile(root .. "modules/" .. m .. ".lua")
end

local paths = {}
local ext_path = reaper.GetExtState("ProjectTimeTracker", "ptt_config_path")
if ext_path and ext_path ~= "" then
  paths[#paths + 1] = ext_path
end
for _, p in ipairs(PTT.config.CANDIDATE_PATHS or {}) do
  paths[#paths + 1] = p
end
local cfg = PTT.config.load_from_paths(paths)
local os_name = reaper.GetOS and reaper.GetOS() or ""
cfg.central_timelogs_dir = PTT.config.adapt_central_dir(cfg.central_timelogs_dir, os_name)

local guid = ""
local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
if ret == 1 and stored and stored ~= "" then
  guid = stored
end

local ctx = {
  cfg = cfg,
  reaper = reaper,
  ident = { guid = guid, saved = guid ~= "" },
}

PTT.notes_ui.open_manual(ctx)
