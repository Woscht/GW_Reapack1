-- test_clean_core_smoke.lua
-- Headless: load clean-core modules inside REAPER and exercise key APIs.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_clean_core_smoke_status.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"

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
  PTT = { _script_root = PKG .. "/" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "bootstrap",
  }
  for _, m in ipairs(mods) do
    local path = PKG .. "/modules/" .. m .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("load " .. m .. ": " .. tostring(err)) end
    chunk()
  end
end

local function main()
  local ok_load, err = pcall(load_modules)
  if not ok_load then
    fail("module load: " .. tostring(err))
    return
  end
  if not (PTT and PTT.util and PTT.activity and PTT.bootstrap) then
    fail("PTT namespaces missing after load")
    return
  end
  if PTT.util.IDLE_GRACE_S ~= 120 or PTT.util.HEARTBEAT_S ~= 30 then
    fail("constants mismatch")
    return
  end

  local prev = {
    edit_cursor = 0, play_cursor = 0, is_dirty = false,
    undo_count = 0, sel_fingerprint = "a",
  }
  local paused = PTT.activity.classify(prev, {
    play_state = 2, edit_cursor = 0, play_cursor = 0,
    is_dirty = false, undo_count = 0, sel_fingerprint = "a",
  })
  if paused.active then
    fail("pause should be inactive")
    return
  end

  local playing = PTT.activity.classify(prev, {
    play_state = 1, edit_cursor = 0, play_cursor = 1,
    is_dirty = false, undo_count = 0, sel_fingerprint = "a",
  })
  if not playing.active then
    fail("play should be active")
    return
  end

  local tmp = "/tmp/ptt_smoke_" .. tostring(os.time())
  os.execute("mkdir -p " .. tmp)
  local log = tmp .. "/TESTGUID.timelog.jsonl"
  local w = PTT.writer.new({ path = log, json_encode = PTT.util.json_encode })
  local wrote = w:append({
    event = "script_start",
    ts = PTT.util.now_iso(reaper.time_precise and reaper.time_precise or nil),
    machine = "smoke-host",
    project_guid = "TESTGUID",
  })
  if not wrote then
    fail("writer append failed")
    return
  end
  local f = io.open(log, "r")
  if not f then
    fail("log missing after write")
    return
  end
  local body = f:read("*a"); f:close()
  if not body:find('"event":"script_start"') then
    fail("log content unexpected")
    return
  end

  -- identity against live REAPER APIs
  local snap = PTT.identity.snapshot({
    get_guid = function()
      local _, guid = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
      return guid or ""
    end,
    get_project_path = function() return reaper.GetProjectPath("") or "" end,
    get_project_name = function()
      local _, fn = reaper.EnumProjects(-1, "")
      return fn or ""
    end,
    is_untitled = function()
      local _, fn = reaper.EnumProjects(-1, "")
      return not fn or fn == ""
    end,
  })
  if type(snap.guid) ~= "string" then
    fail("identity snapshot failed")
    return
  end

  ok(string.format(
    "clean-core smoke passed (guid=%s saved=%s log=%s)",
    snap.guid ~= "" and "yes" or "empty",
    tostring(snap.saved),
    log
  ))
end

local ok_main, err_main = pcall(main)
if not ok_main then
  fail("pcall: " .. tostring(err_main))
end
reaper.defer(function() end)
-- Force quit headless after writing status
if reaper.Main_OnCommand then
  -- 40004 = File: Quit REAPER (may prompt); prefer noop in some builds
end
os.exit(0)
