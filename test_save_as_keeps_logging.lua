-- test_save_as_keeps_logging.lua
-- Reproduce: Save As new name while tracker runs → logging must continue.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_saveas_status.txt"
local DETAIL = os.getenv("PTT_SAVEAS_DETAIL") or "/tmp/ptt_saveas_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local ROOT = "/tmp/ptt_saveas_" .. tostring(os.time())

local function dlog(s)
  local f = io.open(DETAIL, "a"); if f then f:write(s .. "\n"); f:close() end
  reaper.ShowConsoleMsg(s .. "\n")
end

local function status(s)
  local f = io.open(STATUS, "w"); if f then f:write(s .. "\n"); f:close() end
  reaper.ShowConsoleMsg(s .. "\n")
end

local function read_file(p)
  local f = io.open(p, "r"); if not f then return "" end
  local s = f:read("*a"); f:close(); return s or ""
end

local function count_ev(log, ev)
  local n = 0
  for line in log:gmatch("[^\n]+") do
    if line:find('"event":"' .. ev .. '"', 1, true) then n = n + 1 end
  end
  return n
end

local function load_modules()
  PTT = { _script_root = PKG .. "/" }
  for _, m in ipairs({
    "util","activity","session_wall","session_rec","writer","crash","report",
    "path_migrate","untitled","identity","sync_hook","bootstrap"
  }) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
  PTT.util.POLL_S = 0.4
  PTT.util.HEARTBEAT_S = 2
  PTT.util.IDLE_GRACE_S = 3
  PTT.util.SESSION_GAP_S = 20
end

local phase = 0
local t0 = 0
local guid = ""
local log_path = ""
local bytes_before = 0
local name_before = ""

local function fail(msg) status("ERROR: " .. msg) end

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()

  if phase == 0 then
    os.remove(DETAIL)
    os.execute("rm -rf '" .. ROOT .. "' && mkdir -p '" .. ROOT .. "'")
    local ok, err = pcall(load_modules)
    if not ok then fail("load: " .. tostring(err)); return end

    local rpp1 = ROOT .. "/Show.rpp"
    reaper.Main_SaveProjectEx(0, rpp1, 0)
    reaper.Main_openProject("noprompt:" .. rpp1)

    -- seed stable guid like bootstrap
    local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    if ret ~= 1 or stored == "" then
      stored = reaper.genGuid("")
      reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", stored)
      reaper.Main_SaveProjectEx(0, rpp1, 0)
    end
    guid = stored:gsub("[{}]", "")
    log_path = ROOT .. "/" .. guid .. ".timelog.jsonl"
    os.remove(log_path)
    name_before = "Show.rpp"
    dlog("guid=" .. guid .. " log=" .. log_path)

    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    PTT.bootstrap.run(reaper)
    phase = 1
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 1 then
    -- create activity
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.2, false, false)
    if now - t0 < 3 then reaper.defer(step); return end
    local log = read_file(log_path)
    if count_ev(log, "script_start") < 1 or count_ev(log, "session_start") < 1 then
      fail("no initial logging: " .. log:sub(1, 300))
      return
    end
    bytes_before = #log
    dlog("before save-as bytes=" .. bytes_before)

    -- Save As new name SAME folder
    local rpp2 = ROOT .. "/Show_v2.rpp"
    reaper.Main_SaveProjectEx(0, rpp2, 0)
    -- Do NOT reopen — mimics user Save As in-session (project stays loaded as new name)
    local _, fn = reaper.EnumProjects(-1, "")
    dlog("after save-as EnumProjects=" .. tostring(fn))
    local ret, g2 = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    dlog("after save-as guid_ext=" .. tostring(g2) .. " ret=" .. tostring(ret))

    phase = 2
    t0 = now
    reaper.defer(step)
    return
  end

  if phase == 2 then
    -- keep poking activity after rename
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.05, false, false)
    if now - t0 < 5 then reaper.defer(step); return end

    local _, fn = reaper.EnumProjects(-1, "")
    local ret, g2 = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    g2 = (g2 or ""):gsub("[{}]", "")
    dlog("final fn=" .. tostring(fn) .. " guid=" .. g2)

    local log_old = read_file(log_path)
    local bytes_after = #log_old
    dlog("after bytes_old_log=" .. bytes_after)

    -- any other jsonl in folder?
    local handle = io.popen("ls -la '" .. ROOT .. "'")
    dlog("dir:\n" .. (handle and handle:read("*a") or ""))
    if handle then handle:close() end

    local grew = bytes_after > bytes_before
    local hb = count_ev(log_old, "heartbeat")
    local same_guid = (g2 == guid) or (g2 == "")

    -- Also check if a NEW guid log appeared and received writes
    local new_logs = {}
    local h2 = io.popen("ls '" .. ROOT .. "'/*.timelog.jsonl 2>/dev/null")
    local listing = h2 and h2:read("*a") or ""
    if h2 then h2:close() end
    dlog("jsonl files:\n" .. listing)

    local any_grew = grew
    for path in listing:gmatch("([^\n]+)") do
      local body = read_file(path)
      if #body > 0 then
        dlog("file " .. path .. " bytes=" .. #body .. " script_start=" .. count_ev(body, "script_start")
          .. " heartbeat=" .. count_ev(body, "heartbeat")
          .. " session_start=" .. count_ev(body, "session_start"))
      end
    end

    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)

    if not grew then
      fail(string.format(
        "old log did not grow after Save As (before=%d after=%d guid_before=%s guid_after=%s fn=%s). See %s",
        bytes_before, bytes_after, guid, tostring(g2), tostring(fn), DETAIL))
      return
    end
    status(string.format(
      "OK: save-as kept logging old_log %d->%d bytes guid=%s fn=%s",
      bytes_before, bytes_after, guid, tostring(fn)))
  end
end

reaper.defer(step)
