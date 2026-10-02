-- test_mirror_practice_e2e.lua
-- Headless E2E for practice mirror triggers: open, save (debounce), switch, stop.
-- Env: REAPER_HEADLESS_STATUS, PTT_MIRROR_DETAIL, PTT_PKG_ROOT, PTT_SMB_ROOT

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_practice_e2e_status.txt"
local DETAIL = os.getenv("PTT_MIRROR_DETAIL") or "/tmp/ptt_practice_e2e_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local SMB_ROOT = os.getenv("PTT_SMB_ROOT") or "/mnt/cube/01_Projekte/_Temp/ptt_e2e"
local WORK = "/tmp/ptt_practice_e2e_" .. tostring(os.time())

local fails = 0
local phase = 0
local t0 = 0
local guid1, guid2 = "", ""
local local1, local2 = "", ""
local central1, central2 = "", ""
local path1, path2 = "", ""
local open_size = 0
local after_save_size = 0

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

local function file_size(path)
  local s = read_file(path)
  return s and #s or 0
end

local function count_event(log, ev)
  if not log then return 0 end
  local n = 0
  for line in log:gmatch("[^\n]+") do
    if line:find('"event":"' .. ev .. '"', 1, true) then n = n + 1 end
  end
  return n
end

local function shell(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function load_modules()
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.3" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "mirror", "bootstrap",
  }
  for _, m in ipairs(mods) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
  PTT.util.POLL_S = 0.25
  PTT.util.HEARTBEAT_S = 1
  PTT.util.IDLE_GRACE_S = 2
  PTT.util.SESSION_GAP_S = 6
  PTT.util.REC_GAP_S = 6
end

local function resolve_guid()
  local ret, g = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
  if ret == 1 and g and g ~= "" then return tostring(g):gsub("[{}]", "") end
  local ok, sg = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
  if ok and sg and sg ~= "" then return tostring(sg):gsub("[{}]", "") end
  return ""
end

local function finish()
  reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
  dlog("--- summary fails=" .. tostring(fails) .. " ---")
  if fails == 0 then
    write_status("OK: practice mirror e2e guid1=" .. guid1 .. " guid2=" .. guid2)
  else
    write_status("ERROR: practice mirror e2e fails=" .. tostring(fails) .. " detail=" .. DETAIL)
  end
end

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()

  -- PHASE 0: setup + start tracker
  if phase == 0 then
    os.remove(DETAIL)
    shell("rm -rf '" .. WORK .. "' && mkdir -p '" .. WORK .. "/p1' '" .. WORK .. "/p2'")
    shell("mkdir -p '" .. SMB_ROOT .. "/timelogs'")

    -- Linux-readable central path + short debounce for E2E
    local cfg_path = SMB_ROOT .. "/ptt_config.json"
    local cfg = assert(io.open(cfg_path, "w"))
    cfg:write(string.format([[{
  "central_timelogs_dir": "%s/timelogs",
  "mirror_interval_s": 300,
  "mirror_save_debounce_s": 2,
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

    path1 = WORK .. "/p1/PracticeA.rpp"
    path2 = WORK .. "/p2/PracticeB.rpp"
    -- Second project with its own baked tracker GUID (true switch, not Save As).
    do
      local f = assert(io.open(path2, "w"))
      f:write([[<REAPER_PROJECT 0.1 "7.0" 0
  <EXTSTATE
    <PROJECTTIMETRACKER
      PROJECT_GUID {BBBBBBBB-1111-2222-3333-BBBBBBBBBBBB}
    >
  >
>
]])
      f:close()
    end

    reaper.Main_SaveProjectEx(0, path1, 0)
    reaper.Main_openProject("noprompt:" .. path1)

    PTT.bootstrap.run(reaper)
    guid1 = resolve_guid()
    check("guid1", guid1 ~= "", guid1)
    local1 = WORK .. "/p1/" .. guid1 .. ".timelog.jsonl"
    central1 = SMB_ROOT .. "/timelogs/" .. guid1 .. ".timelog.jsonl"

    t0 = now
    phase = 1
    reaper.defer(step)
    return
  end

  -- PHASE 1: wait for open force-mirror
  if phase == 1 then
    if (now - t0) < 2.0 then
      reaper.defer(step)
      return
    end
    local body = read_file(local1)
    check("local1_exists", body ~= nil and body ~= "", local1)
    check("local1_script_start", count_event(body, "script_start") >= 1)

    local cbody = read_file(central1)
    check("open_mirror_central", cbody ~= nil and cbody ~= "", central1)
    if cbody then
      check("open_mirror_script_start", count_event(cbody, "script_start") >= 1)
      open_size = #cbody
    end

    -- dirtify then save (manual save → dirty→clean)
    if reaper.MarkProjectDirty then
      reaper.MarkProjectDirty(0)
    end
    -- small edit: move cursor
    if reaper.SetEditCurPos then
      reaper.SetEditCurPos(1.0, false, false)
    end
    t0 = now
    phase = 2
    reaper.defer(step)
    return
  end

  -- PHASE 2: wait dirty ticks then save
  if phase == 2 then
    if (now - t0) < 1.0 then
      reaper.defer(step)
      return
    end
    reaper.Main_SaveProjectEx(0, path1, 0)
    t0 = now
    phase = 3
    reaper.defer(step)
    return
  end

  -- PHASE 3: wait debounce (2s) + margin for save mirror
  if phase == 3 then
    if (now - t0) < 3.5 then
      reaper.defer(step)
      return
    end
    local cbody = read_file(central1)
    after_save_size = cbody and #cbody or 0
    check("save_mirror_grew_or_refreshed",
      cbody ~= nil and after_save_size >= open_size,
      string.format("open=%d after_save=%d", open_size, after_save_size))

    -- Switch to a different project (not Save As — different RPP without shared GUID)
    reaper.Main_openProject("noprompt:" .. path2)
    t0 = now
    phase = 4
    reaper.defer(step)
    return
  end

  -- PHASE 4: after switch — settle, then assert once
  if phase == 4 then
    if (now - t0) < 3.0 then
      if reaper.SetEditCurPos then reaper.SetEditCurPos(now % 5, false, false) end
      reaper.defer(step)
      return
    end
    guid2 = resolve_guid()
    check("guid2_assigned", guid2 ~= "" and guid2 ~= guid1,
      "g1=" .. guid1 .. " g2=" .. tostring(guid2))
    local2 = WORK .. "/p2/" .. guid2 .. ".timelog.jsonl"
    central2 = SMB_ROOT .. "/timelogs/" .. guid2 .. ".timelog.jsonl"
    if not read_file(local2) then
      local resource = reaper.GetResourcePath and reaper.GetResourcePath() or ""
      local alt = resource:gsub("/+$", "") .. "/" .. guid2 .. ".timelog.jsonl"
      if read_file(alt) then local2 = alt end
    end
    check("switch_old_has_session_end",
      count_event(read_file(central1), "session_end") >= 1, "central1 session_end")
    t0 = now
    phase = 4.5
    reaper.defer(step)
    return
  end

  if phase == 4.5 then
    -- Ensure the new project has local events, then save to trigger debounced mirror
    if (now - t0) < 1.0 then
      if reaper.MarkProjectDirty then reaper.MarkProjectDirty(0) end
      if reaper.SetEditCurPos then reaper.SetEditCurPos(2.0, false, false) end
      reaper.defer(step)
      return
    end
    if (now - t0) < 1.5 then
      reaper.Main_SaveProjectEx(0, path2, 0)
      reaper.defer(step)
      return
    end
    -- debounce_s=2 → wait a bit more
    if (now - t0) < 4.5 then
      reaper.defer(step)
      return
    end
    local new_central = read_file(central2)
    check("switch_new_central", new_central ~= nil and new_central ~= "", central2)
    check("switch_old_still_has_session_end", count_event(read_file(central1), "session_end") >= 1)
    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    t0 = now
    phase = 5
    reaper.defer(step)
    return
  end

  -- PHASE 5: stop flush
  if phase == 5 then
    if (now - t0) < 3.0 then
      reaper.defer(step)
      return
    end
    local local_b = read_file(local2) or ""
    local central_b = read_file(central2) or ""
    check("stop_local_script_stop", count_event(local_b, "script_stop") >= 1)
    check("stop_central_script_stop", count_event(central_b, "script_stop") >= 1,
      "stop mirror includes script_stop")

    finish()
    return
  end
end

reaper.defer(step)
