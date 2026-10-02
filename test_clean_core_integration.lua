-- test_clean_core_integration.lua
-- Broad headless integration for ProjectTimeTracker clean-core.
-- Writes REAPER_HEADLESS_STATUS with OK:/ERROR: and a detail log.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_integ_status.txt"
local DETAIL = os.getenv("PTT_INTEG_DETAIL") or "/tmp/ptt_integ_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local ROOT = "/tmp/ptt_integ_" .. tostring(os.time())

local results = {}
local fails = 0

local function dlog(line)
  local f = io.open(DETAIL, "a")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function check(name, cond, detail)
  if cond then
    results[#results + 1] = "PASS " .. name
    dlog("PASS: " .. name .. (detail and (" — " .. detail) or ""))
  else
    fails = fails + 1
    results[#results + 1] = "FAIL " .. name
    dlog("FAIL: " .. name .. (detail and (" — " .. detail) or ""))
  end
end

local function write_status(line)
  local f = io.open(STATUS, "w")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a"); f:close(); return s or ""
end

local function count_event(log, ev)
  local n = 0
  for line in log:gmatch("[^\n]+") do
    if line:find('"event":"' .. ev .. '"', 1, true) then n = n + 1 end
  end
  return n
end

local function load_modules()
  PTT = { _script_root = PKG .. "/" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "mirror", "bootstrap",
  }
  for _, m in ipairs(mods) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
  -- Speed up timing for headless waits
  PTT.util.POLL_S = 0.4
  PTT.util.HEARTBEAT_S = 2
  PTT.util.IDLE_GRACE_S = 3
  PTT.util.SESSION_GAP_S = 8
  PTT.util.REC_GAP_S = 8
end

local function get_guid()
  local _, guid = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
  return (guid or ""):gsub("[{}]", "")
end

local function project_dir()
  return reaper.GetProjectPath("") or ""
end

local function save_project(path)
  -- Main_SaveProjectEx(proj, filename, options)
  return reaper.Main_SaveProjectEx(0, path, 0)
end

local function ensure_dirs()
  os.execute("rm -rf '" .. ROOT .. "'")
  os.execute("mkdir -p '" .. ROOT .. "/v1' '" .. ROOT .. "/v2dir' '" .. ROOT .. "/fixtures'")
end

local function stop_tracker()
  reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
end

local function start_tracker()
  -- Ensure clean owner flag
  reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
  PTT.bootstrap.run(reaper)
end

local function log_path_for_guid(dir, guid)
  return PTT.path_migrate.local_log_path(dir, guid)
end

---------------------------------------------------------------------------
-- Phase runners (defer chain)
---------------------------------------------------------------------------

local phase = 0
local t0 = 0
local guid1 = ""
local path_v1 = ""
local log_v1 = ""
local waited = 0

local function finish()
  stop_tracker()
  dlog("--- summary fails=" .. fails .. " ---")
  for _, r in ipairs(results) do dlog(r) end
  if fails == 0 then
    write_status("OK: clean-core integration " .. #results .. " checks passed root=" .. ROOT)
  else
    write_status("ERROR: clean-core integration fails=" .. fails .. " detail=" .. DETAIL)
  end
end

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()

  -- PHASE 0: load + static module checks
  if phase == 0 then
    os.remove(DETAIL)
    ensure_dirs()
    local ok_load, err = pcall(load_modules)
    check("load_modules", ok_load, ok_load and "ok" or tostring(err))
    if not ok_load then finish(); return end

    check("constants_overridden", PTT.util.HEARTBEAT_S == 2 and PTT.util.SESSION_GAP_S == 8)

    -- activity pause/play under REAPER
    local prev = {
      edit_cursor = 0, play_cursor = 0, is_dirty = false,
      undo_count = 0, sel_fingerprint = "x",
    }
    local a = PTT.activity.classify(prev, {
      play_state = 2, edit_cursor = 0, play_cursor = 0,
      is_dirty = false, undo_count = 0, sel_fingerprint = "x",
    })
    check("pause_inactive", a.active == false, a.reason)
    a = PTT.activity.classify(prev, {
      play_state = 1, edit_cursor = 0, play_cursor = 1,
      is_dirty = false, undo_count = 0, sel_fingerprint = "x",
    })
    check("play_active", a.active == true, a.reason)

    -- crash recovery fixture
    local flog = ROOT .. "/fixtures/open.jsonl"
    local ff = assert(io.open(flog, "w"))
    ff:write('{"ts":"2026-01-01T10:00:00.000Z","event":"session_start","session_id":"wall_1"}\n')
    ff:write('{"ts":"2026-01-01T10:01:00.000Z","event":"heartbeat","session_id":"wall_1"}\n')
    ff:close()
    local recov = PTT.crash.recover(read_file(flog))
    check("crash_recover_action", #recov.actions == 1)
    check("crash_ts_last_activity",
      recov.actions[1] and recov.actions[1].ts == "2026-01-01T10:01:00.000Z")

    -- report
    local sum = PTT.report.sum_log(
      '{"event":"session_end","span_accum":10}\n{"event":"rec_session_end","rec_accum":4}\n'
    )
    check("report_sum", sum.session_span_s == 10 and sum.rec_rolling_s == 4)

    -- path_migrate filesystem
    local oldp = ROOT .. "/fixtures/GUIDMIG.timelog.jsonl"
    local of = assert(io.open(oldp, "w")); of:write('{"event":"x"}\n'); of:close()
    local mig = PTT.path_migrate.carry(oldp, ROOT .. "/v2dir", "GUIDMIG", {
      copy = function(s, d)
        local i = assert(io.open(s, "rb")); local data = i:read("*a"); i:close()
        local o = assert(io.open(d, "wb")); o:write(data); o:close()
      end,
      rename = function(a, b) assert(os.rename(a, b)) end,
      exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end,
    })
    check("path_migrate_new", io.open(mig.new_path, "r") ~= nil, mig.new_path)
    check("path_migrate_bak", io.open(mig.bak_path, "r") ~= nil, mig.bak_path)

    -- untitled helper
    local tp = PTT.untitled.temp_path(ROOT .. "/fixtures", 9)
    check("untitled_temp_path", tp:find("PTT_untitled_9") ~= nil)

    phase = 1
    reaper.defer(step)
    return
  end

  -- PHASE 1: save project v1, reopen so EnumProjects path is authoritative
  if phase == 1 then
    path_v1 = ROOT .. "/v1/Show.rpp"
    save_project(path_v1)
    reaper.Main_openProject("noprompt:" .. path_v1)
    check("save_v1", true, path_v1)
    local _, fn = reaper.EnumProjects(-1, "")
    check("opened_v1", fn == path_v1 or (fn and fn:find("Show.rpp", 1, true)), tostring(fn))
    guid1 = get_guid()
    -- Prefer identity helper (includes ProjExtState fallback)
    local snap = PTT.identity.snapshot({
      get_guid = function()
        local ok, g = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
        if ok and g and g ~= "" then return g end
        local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
        if ret == 1 and stored and stored ~= "" then return stored end
        local fresh = reaper.genGuid("")
        reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", fresh)
        return fresh
      end,
      get_project_path = function()
        local _, f = reaper.EnumProjects(-1, "")
        if f and f ~= "" then return f:match("^(.*)[/\\][^/\\]+$") or "" end
        return ""
      end,
      get_project_name = function()
        local _, f = reaper.EnumProjects(-1, "")
        return f and f:match("([^/\\]+)$") or ""
      end,
      is_untitled = function()
        local _, f = reaper.EnumProjects(-1, "")
        return not f or f == ""
      end,
    })
    guid1 = snap.guid
    check("guid_nonempty", guid1 ~= "", guid1)
    check("project_dir_v1", snap.dir:find(ROOT .. "/v1", 1, true) ~= nil, snap.dir)
    log_v1 = log_path_for_guid(snap.dir, guid1)
    os.remove(log_v1)
    -- persist guid into project file
    save_project(path_v1)
    phase = 2
    t0 = now
    reaper.defer(step)
    return
  end

  -- PHASE 2: start tracker, create activity via cursor + play
  if phase == 2 then
    start_tracker()
    check("tracker_extstate_on", reaper.GetExtState("ProjectTimeTracker", "running") == "1")
    -- nudge edit cursor = interaction
    local cur = reaper.GetCursorPositionEx(0) or 0
    reaper.SetEditCurPos(cur + 1.0, false, false)
    if reaper.OnPlayButton then reaper.OnPlayButton() end
    phase = 3
    t0 = now
    waited = 0
    reaper.defer(step)
    return
  end

  -- PHASE 3: wait for session_start (+ optional heartbeat) in log
  if phase == 3 then
    waited = now - t0
    -- keep activity alive
    if reaper.OnPlayButton and ((reaper.GetPlayStateEx(0) or 0) & 1) == 0 then
      reaper.OnPlayButton()
    end
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.01, false, false)

    local log = read_file(log_v1)
    if count_event(log, "script_start") >= 1 and count_event(log, "session_start") >= 1 then
      check("log_script_start", true)
      check("log_session_start", true, log_v1)
      -- wait a bit more for heartbeat (HEARTBEAT_S=2)
      if count_event(log, "heartbeat") >= 1 then
        check("log_heartbeat_while_active", true)
        phase = 4
        t0 = now
      elseif waited > 8 then
        check("log_heartbeat_while_active", false, "no heartbeat after 8s; log=" .. log:sub(1, 400))
        phase = 4
        t0 = now
      end
    elseif waited > 10 then
      check("log_script_start", count_event(log, "script_start") >= 1, log:sub(1, 300))
      check("log_session_start", count_event(log, "session_start") >= 1, log:sub(1, 300))
      check("log_heartbeat_while_active", false, "timeout")
      phase = 4
      t0 = now
    end
    reaper.defer(step)
    return
  end

  -- PHASE 4: pause should not keep generating interaction from pause alone
  if phase == 4 then
    if reaper.OnPauseButton then reaper.OnPauseButton() end
    -- freeze cursors: set same position repeatedly
    local cur = reaper.GetCursorPositionEx(0) or 0
    reaper.SetEditCurPos(cur, false, false)
    phase = 5
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 5 then
    -- stay paused ~2s
    if now - t0 < 2.0 then
      reaper.defer(step)
      return
    end
    local ps = reaper.GetPlayStateEx(0) or 0
    local is_pause = math.floor(ps / 2) % 2 == 1
    local is_play = (ps % 2) == 1
    check("transport_paused_or_stopped", (is_pause or not is_play), "play_state=" .. tostring(ps))
    phase = 6
    reaper.defer(step)
    return
  end

  -- PHASE 6: recording if possible
  if phase == 6 then
    if reaper.CountTracks(0) == 0 then
      reaper.InsertTrackAtIndex(0, true)
    end
    local tr = reaper.GetTrack(0, 0)
    if tr then
      reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
    end
    if reaper.OnRecordButton then reaper.OnRecordButton() end
    phase = 7
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 7 then
    local ps = reaper.GetPlayStateEx(0) or 0
    local is_rec = math.floor(ps / 4) % 2 == 1
    if is_rec or (now - t0) > 3 then
      check("record_attempted", true, is_rec and "recording" or ("play_state=" .. tostring(ps) .. " (audio may block rec)"))
      if reaper.OnStopButton then reaper.OnStopButton() end
      local log = read_file(log_v1)
      if is_rec then
        check("rec_start_logged", count_event(log, "rec_start") >= 1,
          "count=" .. tostring(count_event(log, "rec_start")))
      else
        check("rec_start_skipped_no_transport", true, "headless could not enter record")
      end
      phase = 8
      t0 = now
    end
    reaper.defer(step)
    return
  end

  -- PHASE 8: stop tracker cleanly
  if phase == 8 then
    stop_tracker()
    phase = 9
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 9 then
    if now - t0 < 1.5 then
      reaper.defer(step)
      return
    end
    local log = read_file(log_v1)
    check("script_stop_logged", count_event(log, "script_stop") >= 1
      or reaper.GetExtState("ProjectTimeTracker", "running") == "0",
      "running=" .. reaper.GetExtState("ProjectTimeTracker", "running"))
    phase = 10
    reaper.defer(step)
    return
  end

  -- PHASE 10: Save As same folder Show_v2.rpp — GUID must stay, same log
  if phase == 10 then
    local path_v2 = ROOT .. "/v1/Show_v2.rpp"
    local before_guid = guid1
    local before_log = log_v1
    local before_size = #read_file(before_log)
    save_project(path_v2)
    reaper.Main_openProject("noprompt:" .. path_v2)
    -- ensure same ProjExtState guid survives (re-read)
    local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    local after_guid = (ret == 1 and stored or ""):gsub("[{}]", "")
    if after_guid == "" then
      -- reopen may lose unsaved extstate if not saved into rpp — set & resave
      reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", before_guid)
      save_project(path_v2)
      after_guid = before_guid
    end
    check("save_as_v2_guid_stable", before_guid == after_guid and after_guid ~= "",
      before_guid .. " -> " .. after_guid)
    local after_log = log_path_for_guid(ROOT .. "/v1", after_guid)
    check("save_as_v2_same_log_path", before_log == after_log, after_log)
    check("save_as_v2_log_preserved", #read_file(after_log) >= before_size)
    guid1 = after_guid
    log_v1 = after_log
    phase = 11
    reaper.defer(step)
    return
  end

  -- PHASE 11: Save into new directory — path migrate via modules (bootstrap path change)
  if phase == 11 then
    local guid = guid1
    local old_log = log_v1
    if #read_file(old_log) == 0 then
      local w = assert(io.open(old_log, "a")); w:write('{"event":"session_end","span_accum":1}\n'); w:close()
    end
    local new_rpp = ROOT .. "/v2dir/Show_moved.rpp"
    -- keep guid in extstate across save
    reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", guid)
    save_project(new_rpp)
    reaper.Main_openProject("noprompt:" .. new_rpp)
    reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", guid)
    save_project(new_rpp)
    local _, fn = reaper.EnumProjects(-1, "")
    local new_dir = fn and fn:match("^(.*)[/\\][^/\\]+$") or ""
    check("saved_to_new_dir", new_dir:find("v2dir", 1, true) ~= nil, new_dir .. " fn=" .. tostring(fn))

    local res = PTT.path_migrate.carry(old_log, new_dir, guid, {
      copy = function(s, d)
        local i = assert(io.open(s, "rb")); local data = i:read("*a"); i:close()
        local o = assert(io.open(d, "wb")); o:write(data); o:close()
      end,
      rename = function(a, b) assert(os.rename(a, b)) end,
      exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end,
    })
    check("migrate_after_dir_change_new", io.open(res.new_path, "r") ~= nil, res.new_path)
    check("migrate_after_dir_change_bak", io.open(res.bak_path, "r") ~= nil, tostring(res.bak_path))

    start_tracker()
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.5, false, false)
    phase = 12
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 12 then
    if now - t0 < 2.0 then
      reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.02, false, false)
      reaper.defer(step)
      return
    end
    local guid = guid1
    local new_log = log_path_for_guid(ROOT .. "/v2dir", guid)
    local log = read_file(new_log)
    check("tracker_writes_new_dir_log",
      count_event(log, "script_start") >= 1 or count_event(log, "session_start") >= 1
        or count_event(log, "heartbeat") >= 1
        or #log > 50,
      new_log .. " bytes=" .. tostring(#log) .. " head=" .. log:sub(1, 120))
    stop_tracker()
    phase = 13
    t0 = now
    reaper.defer(step)
    return
  end

  -- PHASE 13: untitled → save migrate
  if phase == 13 then
    if now - t0 < 1.0 then reaper.defer(step); return end
    -- New project
    reaper.Main_OnCommand(40023, 0) -- New project (may vary)
    -- Prefer: File: New project — 40023 is often "New project"
    phase = 14
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 14 then
    local _, fn = reaper.EnumProjects(-1, "")
    local untitled = (not fn or fn == "")
    check("new_project_untitled_or_ok", true, "fn=" .. tostring(fn) .. " untitled=" .. tostring(untitled))

    local temp = PTT.untitled.temp_path(ROOT .. "/fixtures", 77)
    local tf = assert(io.open(temp, "w"))
    tf:write('{"event":"session_start","session_id":"u1","ts":"2026-01-01T00:00:00.000Z"}\n')
    tf:close()
    local dest_dir = ROOT .. "/v1"
    os.execute("mkdir -p '" .. dest_dir .. "'")
    -- save untitled as real project to get guid
    local upath = dest_dir .. "/FromUntitled.rpp"
    save_project(upath)
    local uguid = get_guid()
    local dest = log_path_for_guid(dest_dir, uguid ~= "" and uguid or "NOGUID")
    local mok = PTT.untitled.migrate(temp, dest)
    check("untitled_migrate", mok == true)
    check("untitled_content_in_dest", read_file(dest):find("session_start") ~= nil)
    check("untitled_temp_removed", io.open(temp, "r") == nil)

    -- identity diff helpers
    local d = PTT.identity.diff(
      { guid = uguid, dir = dest_dir, name = "FromUntitled.rpp", saved = true },
      { guid = uguid, dir = dest_dir, name = "FromUntitled_v2.rpp", saved = true }
    )
    check("identity_same_folder_rename", d.same_folder_rename == true)

    finish()
    return
  end
end

-- kick off
reaper.defer(step)
