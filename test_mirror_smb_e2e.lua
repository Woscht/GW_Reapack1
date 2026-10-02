-- test_mirror_smb_e2e.lua
-- Headless E2E: tracker mirrors local JSONL to SMB share via ptt_config.json.
-- Expects env:
--   PTT_SMB_ROOT   (default /mnt/cube/01_Projekte/_Temp/ptt_e2e)
--   PTT_PKG_ROOT
--   REAPER_HEADLESS_STATUS
--   PTT_MIRROR_DETAIL

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_mirror_smb_status.txt"
local DETAIL = os.getenv("PTT_MIRROR_DETAIL") or "/tmp/ptt_mirror_smb_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local SMB_ROOT = os.getenv("PTT_SMB_ROOT") or "/mnt/cube/01_Projekte/_Temp/ptt_e2e"
local WORK = "/tmp/ptt_mirror_smb_" .. tostring(os.time())

local fails = 0
local phase = 0
local t0 = 0
local guid = ""
local local_log = ""
local central_log = ""
local project_path = ""

local function dlog(line)
  local f = io.open(DETAIL, "a")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function check(name, cond, detail)
  if cond then
    dlog("PASS: " .. name .. (detail and (" — " .. detail) or ""))
  else
    fails = fails + 1
    dlog("FAIL: " .. name .. (detail and (" — " .. detail) or ""))
  end
end

local function write_status(line)
  local f = io.open(STATUS, "w")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function count_event(log, ev)
  if not log then return 0 end
  local n = 0
  for line in log:gmatch("[^\n]+") do
    if line:find('"event":"' .. ev .. '"', 1, true) then n = n + 1 end
  end
  return n
end

local function load_modules()
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.0" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "mirror", "bootstrap",
  }
  for _, m in ipairs(mods) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
  PTT.util.POLL_S = 0.3
  PTT.util.HEARTBEAT_S = 1
  PTT.util.IDLE_GRACE_S = 2
  PTT.util.SESSION_GAP_S = 6
  PTT.util.REC_GAP_S = 6
end

local function shell(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function finish()
  reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
  dlog("--- summary fails=" .. tostring(fails) .. " ---")
  if fails == 0 then
    write_status("OK: mirror smb e2e guid=" .. guid .. " central=" .. central_log)
  else
    write_status("ERROR: mirror smb e2e fails=" .. tostring(fails) .. " detail=" .. DETAIL)
  end
end

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()

  if phase == 0 then
    os.remove(DETAIL)
    shell("rm -rf '" .. WORK .. "' && mkdir -p '" .. WORK .. "/proj'")
    shell("mkdir -p '" .. SMB_ROOT .. "/timelogs'")

    local cfg_path = SMB_ROOT .. "/ptt_config.json"
    local cfg = assert(io.open(cfg_path, "w"))
    cfg:write(string.format([[{
  "central_timelogs_dir": "%s/timelogs",
  "mirror_interval_s": 5,
  "mirror_enabled": true
}
]], SMB_ROOT))
    cfg:close()
    dlog("config=" .. cfg_path)

    local ok_load, err = pcall(load_modules)
    check("load_modules", ok_load, ok_load and "ok" or tostring(err))
    if not ok_load then finish(); return end

    reaper.SetExtState("ProjectTimeTracker", "ptt_config_path", cfg_path, true)
    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)

    project_path = WORK .. "/proj/MirrorE2E.rpp"
    reaper.Main_SaveProjectEx(0, project_path, 0)
    reaper.Main_openProject("noprompt:" .. project_path)
    check("project_saved", true, project_path)

    local _, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    -- start tracker (creates guid + local log)
    PTT.bootstrap.run(reaper)

    -- resolve identity after start
    local ret, g = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    guid = (ret == 1 and g) or stored or ""
    if guid == "" then
      local ok, sg = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
      if ok and sg and sg ~= "" then guid = sg end
    end
    guid = tostring(guid):gsub("[{}]", "")
    check("guid_assigned", guid ~= "", guid)

    -- Discover local log (next to .rpp for saved projects)
    local_log = WORK .. "/proj/" .. guid .. ".timelog.jsonl"
    if not read_file(local_log) then
      local resource = reaper.GetResourcePath and reaper.GetResourcePath() or ""
      local_log = resource:gsub("/+$", "") .. "/" .. guid .. ".timelog.jsonl"
    end
    central_log = SMB_ROOT .. "/timelogs/" .. guid .. ".timelog.jsonl"
    os.remove(central_log)

    t0 = now
    phase = 1
    reaper.defer(step)
    return
  end

  if phase == 1 then
    -- Keep session alive briefly so local JSONL has events
    if reaper.OnPlayButton and ((reaper.GetPlayStateEx(0) or 0) & 1) == 0 then
      reaper.OnPlayButton()
    end
    if (now - t0) < 2.5 then
      reaper.defer(step)
      return
    end
    if reaper.OnStopButton then reaper.OnStopButton() end

    local body = read_file(local_log)
    check("local_log_exists", body ~= nil and body ~= "", local_log)
    check("local_has_script_start", count_event(body, "script_start") >= 1)
    check("local_has_session_start", count_event(body, "session_start") >= 1)

    -- Request stop; next tracker tick will emit script_stop then force-mirror
    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    t0 = now
    phase = 2
    reaper.defer(step)
    return
  end

  if phase == 2 then
    -- Wait for stop tick + mirror
    if (now - t0) < 3.0 then
      reaper.defer(step)
      return
    end

    local local_body = read_file(local_log) or ""
    check("local_has_script_stop", count_event(local_body, "script_stop") >= 1)

    local central_body = read_file(central_log)
    check("central_mirror_exists", central_body ~= nil and central_body ~= "", central_log)
    if central_body then
      check("central_has_script_start", count_event(central_body, "script_start") >= 1)
      check("central_has_session_start", count_event(central_body, "session_start") >= 1)
      check("central_has_script_stop", count_event(central_body, "script_stop") >= 1,
        "verifies stop-mirror order fix")
      check("central_matches_local_len", #central_body == #local_body,
        string.format("central=%d local=%d", #central_body, #local_body))
      local ver_ok = central_body:find('"version":"2.1.0"', 1, true) ~= nil
        or central_body:find('"version": "2.1.0"', 1, true) ~= nil
      check("central_version_2_1_0", ver_ok)
    end

    finish()
    return
  end
end

reaper.defer(step)
