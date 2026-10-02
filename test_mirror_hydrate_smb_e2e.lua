-- test_mirror_hydrate_smb_e2e.lua
-- Headless E2E: central history for GUID → open local project without log → hydrate →
-- continue logging → central never shrinks.
-- Env: REAPER_HEADLESS_STATUS, PTT_MIRROR_DETAIL, PTT_PKG_ROOT, PTT_SMB_ROOT

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_hydrate_smb_status.txt"
local DETAIL = os.getenv("PTT_MIRROR_DETAIL") or "/tmp/ptt_hydrate_smb_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local SMB_ROOT = os.getenv("PTT_SMB_ROOT") or "/mnt/cube/01_Projekte/_Temp/ptt_e2e"
local WORK = "/tmp/ptt_hydrate_smb_" .. tostring(os.time())

local fails = 0
local phase = 0
local t0 = 0
local guid = "HYDRATEE2E001"
local local_log = ""
local central_log = ""
local project_path = ""
local central_seed_lines = 0

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

local function line_count(text)
  if not text or text == "" then return 0 end
  local n = 0
  for _ in text:gmatch("[^\r\n]+") do n = n + 1 end
  return n
end

local function shell(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function load_modules()
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.6" }
  for _, m in ipairs({
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "mirror", "bootstrap",
  }) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
  PTT.util.POLL_S = 0.3
  PTT.util.HEARTBEAT_S = 60
  PTT.util.IDLE_GRACE_S = 2
  PTT.util.SESSION_GAP_S = 30
  PTT.util.REC_GAP_S = 30
end

local function finish()
  reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
  dlog("--- summary fails=" .. tostring(fails) .. " ---")
  if fails == 0 then
    write_status("OK: hydrate smb e2e guid=" .. guid)
  else
    write_status("ERROR: hydrate smb e2e fails=" .. tostring(fails) .. " detail=" .. DETAIL)
  end
end

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()

  if phase == 0 then
    os.remove(DETAIL)
    shell("rm -rf '" .. WORK .. "' && mkdir -p '" .. WORK .. "/proj/timetracker'")
    shell("mkdir -p '" .. SMB_ROOT .. "/timelogs'")

    local cfg_path = SMB_ROOT .. "/ptt_config.json"
    local cfg = assert(io.open(cfg_path, "w"))
    cfg:write(string.format([[
{
  "central_timelogs_dir": "%s/timelogs",
  "mirror_interval_s": 5,
  "mirror_save_debounce_s": 2,
  "mirror_enabled": true
}
]], SMB_ROOT))
    cfg:close()

    central_log = SMB_ROOT .. "/timelogs/" .. guid .. ".timelog.jsonl"
    local_log = WORK .. "/proj/timetracker/" .. guid .. ".timelog.jsonl"
    -- Seed central history (as if prior machine mirrored days of work).
    local seed = assert(io.open(central_log, "w"))
    seed:write('{"event":"session_end","span_accum":100,"session_id":"wall_old"}\n')
    seed:write('{"event":"rec_session_end","rec_accum":40,"session_id":"rec_old"}\n')
    seed:write('{"event":"session_end","span_accum":200,"session_id":"wall_old2"}\n')
    seed:close()
    central_seed_lines = 3
    -- Ensure NO local log (cold open on new path / machine).
    os.remove(local_log)

    local ok, err = pcall(load_modules)
    if not ok then
      write_status("ERROR: load " .. tostring(err))
      return
    end

    reaper.SetExtState("ProjectTimeTracker", "ptt_config_path", cfg_path, true)
    project_path = WORK .. "/proj/Show_hydrate.rpp"
    reaper.Main_SaveProjectEx(0, project_path, 0)
    reaper.Main_openProject("noprompt:" .. project_path)
    reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", guid)
    reaper.Main_SaveProjectEx(0, project_path, 0)

    check("central_seeded", line_count(read_file(central_log)) == 3)
    check("local_absent", read_file(local_log) == nil)

    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    PTT.bootstrap.run(reaper)

    phase = 1
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 1 then
    -- Wait for hydrate + script_start on local
    if now - t0 < 4.0 then
      reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.02, false, false)
      reaper.defer(step)
      return
    end
    local local_body = read_file(local_log)
    check("local_hydrated", local_body ~= nil and local_body ~= "", tostring(local_log))
    check("local_has_seed_history",
      local_body and local_body:find("wall_old", 1, true) ~= nil and local_body:find("rec_old", 1, true) ~= nil)
    check("local_at_least_seed", line_count(local_body) >= central_seed_lines,
      "lines=" .. tostring(line_count(local_body)))
    check("local_has_script_start",
      local_body and local_body:find('"event":"script_start"', 1, true) ~= nil)

    -- Never-shrink probe: try push of artificially short local via maybe_mirror
    local short = WORK .. "/proj/timetracker/" .. guid .. ".short.jsonl"
    local sf = assert(io.open(short, "w"))
    sf:write('{"event":"tiny"}\n')
    sf:close()
    local central_before = read_file(central_log)
    local cfg = select(1, PTT.config.load_from_paths({ SMB_ROOT .. "/ptt_config.json" }))
    local fake_ctx = {
      cfg = cfg,
      ident = { guid = guid },
      writer = { path = short },
      last_mirror_ts = 0,
      last_mirror_warn_ts = 0,
      now = function() return os.time() end,
      reaper = reaper,
    }
    local mok, merr = pcall(function()
      PTT.mirror.maybe_mirror(fake_ctx, { force = true })
    end)
    check("never_shrink_call_ok", mok, tostring(merr))
    check("never_shrink_central", read_file(central_log) == central_before)

    -- Generate activity then force mirror from real writer path
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.5, false, false)
    phase = 2
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 2 then
    if now - t0 < 3.0 then
      reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.05, false, false)
      reaper.defer(step)
      return
    end
    -- Request stop so script_stop + final mirror run
    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    phase = 3
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 3 then
    if now - t0 < 3.0 then
      reaper.defer(step)
      return
    end
    local central_body = read_file(central_log)
    local local_body = read_file(local_log)
    check("central_still_has_seed",
      central_body and central_body:find("wall_old", 1, true) ~= nil)
    check("central_not_shorter_than_seed",
      line_count(central_body) >= central_seed_lines,
      "central_lines=" .. tostring(line_count(central_body)))
    check("central_grew_or_matched_local",
      line_count(central_body) >= math.min(line_count(local_body), central_seed_lines),
      string.format("c=%d l=%d", line_count(central_body), line_count(local_body)))
    -- After real work, local should be >= seed; if mirror ran, central should include script_start
    if line_count(local_body) >= central_seed_lines + 1 then
      check("central_has_script_start_after_push",
        central_body and central_body:find('"event":"script_start"', 1, true) ~= nil)
    end
    finish()
    return
  end
end

reaper.defer(step)
