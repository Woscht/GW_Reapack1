-- test_notes_ui_headless.lua
-- Headless REAPER: load PTT notes_ui/mirror/config and verify gated auto-open.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_notes_ui_headless_status.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local OFFICE = os.getenv("NOTES_UI_BASE") or "http://127.0.0.1:3001"

local function write_status(line)
  local f = io.open(STATUS, "w")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function fail(msg)
  write_status("ERROR: " .. msg)
end

local function ok(msg)
  write_status("OK: " .. msg)
end

local function load_modules()
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.7" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "mirror", "notes_ui", "bootstrap",
  }
  for _, m in ipairs(mods) do
    local path = PKG .. "/modules/" .. m .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("load " .. m .. ": " .. tostring(err)) end
    chunk()
  end
end

local function main()
  local loaded, err = pcall(load_modules)
  if not loaded then
    fail("module load: " .. tostring(err))
    return
  end
  if not (PTT.notes_ui and PTT.mirror and PTT.config) then
    fail("notes_ui/mirror/config missing")
    return
  end

  local cfg = PTT.config.load_from_text(string.format([[{
    "notes_ui_base_url": "%s",
    "notes_auto_open": true,
    "mirror_enabled": false
  }]], OFFICE))
  if cfg.notes_ui_base_url ~= OFFICE then
    fail("config notes_ui_base_url")
    return
  end

  local opened = {}
  local ctx = {
    cfg = cfg,
    ident = { guid = "HEADLESS-NOTES-001", saved = true },
    now = function() return os.time() end,
    notes_last_open_ts = {},
    reaper = reaper,
  }

  local did, reason = PTT.notes_ui.maybe_auto_open(ctx, {
    http_get = function() return '{"blocks":2,"missing":2}' end,
    open_fn = function(url) opened[#opened + 1] = url end,
  })
  if not did or reason ~= "opened" then
    fail("auto_open missing>0: " .. tostring(reason))
    return
  end
  if not opened[1] or not opened[1]:find("src=reaper", 1, true) then
    fail("url missing src=reaper: " .. tostring(opened[1]))
    return
  end

  did, reason = PTT.notes_ui.maybe_auto_open(ctx, {
    http_get = function() return '{"blocks":2,"missing":2}' end,
    open_fn = function(url) opened[#opened + 1] = url end,
  })
  if did or reason ~= "rate_limited" then
    fail("expected rate_limited, got " .. tostring(reason))
    return
  end

  did, reason = PTT.notes_ui.maybe_auto_open({
    cfg = cfg,
    ident = { guid = "HEADLESS-NOTES-002", saved = true },
    now = function() return os.time() end,
    notes_last_open_ts = {},
    reaper = reaper,
  }, {
    http_get = function() return '{"blocks":2,"missing":0}' end,
    open_fn = function() error("must not open") end,
  })
  if did or reason ~= "complete" then
    fail("expected complete, got " .. tostring(reason))
    return
  end

  -- Live status against office if reachable
  local live = PTT.notes_ui.default_http_get(OFFICE .. "/projects/GUID-BLOCKS-001/notes/status?from=2026-10-01&to=2026-10-31", 2)
  if live and live:find('"missing"') then
    ok("notes_ui gated open + live status OK: " .. live:gsub("%s+", " "))
  else
    ok("notes_ui gated open OK (office status not reachable: " .. tostring(live) .. ")")
  end
end

local ran, err = pcall(main)
if not ran then
  fail("pcall: " .. tostring(err))
end

reaper.defer(function()
  reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
end)
