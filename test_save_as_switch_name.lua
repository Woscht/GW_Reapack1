-- test_save_as_switch_name.lua
-- Simulate true Save As: new filename becomes the active project while tracker runs.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS") or "/tmp/ptt_saveas2_status.txt"
local DETAIL = os.getenv("PTT_SAVEAS_DETAIL") or "/tmp/ptt_saveas2_detail.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local ROOT = "/tmp/ptt_saveas2_" .. tostring(os.time())

local function dlog(s)
  local f = io.open(DETAIL, "a"); if f then f:write(s .. "\n"); f:close() end
  reaper.ShowConsoleMsg(s .. "\n")
end
local function status(s)
  local f = io.open(STATUS, "w"); if f then f:write(s .. "\n"); f:close() end
end
local function read_file(p)
  local f = io.open(p, "r"); if not f then return "" end
  local s = f:read("*a"); f:close(); return s or ""
end
local function count_ev(log, ev)
  local n = 0
  for line in (log or ""):gmatch("[^\n]+") do
    if line:find('"event":"' .. ev .. '"', 1, true) then n = n + 1 end
  end
  return n
end

local function load_modules()
  PTT = { _script_root = PKG .. "/" }
  for _, m in ipairs({
    "util","activity","session_wall","session_rec","writer","crash","report",
    "path_migrate","untitled","identity","sync_hook","config","mirror","bootstrap"
  }) do assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))() end
  PTT.util.POLL_S = 0.4
  PTT.util.HEARTBEAT_S = 2
end

local phase, t0, guid, log_path, bytes_before = 0, 0, "", "", 0

local function step()
  local now = reaper.time_precise and reaper.time_precise() or os.clock()
  if phase == 0 then
    os.remove(DETAIL)
    os.execute("rm -rf '" .. ROOT .. "' && mkdir -p '" .. ROOT .. "'")
    assert(pcall(load_modules))
    local rpp1 = ROOT .. "/Show.rpp"
    reaper.Main_SaveProjectEx(0, rpp1, 0)
    reaper.Main_openProject("noprompt:" .. rpp1)
    local g = reaper.genGuid("")
    reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", g)
    reaper.Main_SaveProjectEx(0, rpp1, 0)
    guid = g:gsub("[{}]", "")
    log_path = PTT.path_migrate.local_log_path(ROOT, guid)
    os.remove(log_path)
    dlog("start guid=" .. guid .. " log=" .. log_path)
    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
    PTT.bootstrap.run(reaper)
    phase = 1; t0 = now
    reaper.defer(step); return
  end

  if phase == 1 then
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.1, false, false)
    if now - t0 < 3 then reaper.defer(step); return end
    local log = read_file(log_path)
    if count_ev(log, "session_start") < 1 then
      status("ERROR: no session_start before rename: " .. log:sub(1, 200)); return
    end
    bytes_before = #log
    dlog("bytes_before=" .. bytes_before)

    -- True Save-As simulation: save content to new name, then make it the active project
    local rpp2 = ROOT .. "/Show_VERSION2.rpp"
    reaper.Main_SaveProjectEx(0, rpp2, 0)
    reaper.Main_openProject("noprompt:" .. rpp2)
    local _, fn = reaper.EnumProjects(-1, "")
    local ret, g2 = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    dlog("switched fn=" .. tostring(fn) .. " guid=" .. tostring(g2) .. " ret=" .. tostring(ret))
    phase = 2; t0 = now
    reaper.defer(step); return
  end

  if phase == 2 then
    reaper.SetEditCurPos((reaper.GetCursorPositionEx(0) or 0) + 0.05, false, false)
    if now - t0 < 5 then reaper.defer(step); return end

    local _, fn = reaper.EnumProjects(-1, "")
    local ret, g2 = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    g2 = (g2 or ""):gsub("[{}]", "")
    local log = read_file(log_path)
    local h = io.popen("ls -la '" .. ROOT .. "'/*.timelog.jsonl '" .. ROOT .. "/timetracker'/*.timelog.jsonl '" .. ROOT .. "'/*.bak 2>/dev/null; ls -la '" .. ROOT .. "' '" .. ROOT .. "/timetracker' 2>/dev/null")
    dlog(h and h:read("*a") or "")
    if h then h:close() end

    -- dump all jsonl sizes
    local h2 = io.popen("ls '" .. ROOT .. "'/*.timelog.jsonl '" .. ROOT .. "/timetracker'/*.timelog.jsonl 2>/dev/null")
    local listing = h2 and h2:read("*a") or ""
    if h2 then h2:close() end
    local total_new_bytes = 0
    local any_post = false
    for path in listing:gmatch("([^\n]+)") do
      local body = read_file(path)
      dlog(string.format("LOG %s bytes=%d hb=%d ss=%d start=%d name_in_last=%s",
        path, #body, count_ev(body, "heartbeat"), count_ev(body, "session_start"),
        count_ev(body, "script_start"), body:match('"project_name":"([^"]*)"') or "?"))
      if path == log_path and #body > bytes_before then any_post = true end
      if path ~= log_path and #body > 0 then
        total_new_bytes = total_new_bytes + #body
        if count_ev(body, "heartbeat") > 0 or count_ev(body, "session_start") > 0 then
          any_post = true
        end
      end
    end

    reaper.SetExtState("ProjectTimeTracker", "running", "0", true)

    dlog(string.format("guid_before=%s guid_after=%s fn=%s old_grew=%s",
      guid, g2, tostring(fn), tostring(#log > bytes_before)))

    if #log > bytes_before then
      status("OK: continued on same guid log after Save-As switch")
    elseif any_post then
      status("ERROR: logging moved/split unexpectedly after Save-As (see detail)")
    else
      status("ERROR: no jsonl grew after Save-As name switch (see detail)")
    end
  end
end

reaper.defer(step)
