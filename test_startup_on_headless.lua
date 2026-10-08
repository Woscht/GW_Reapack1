-- test_startup_on_headless.lua
-- Headless: enable/disable __startup.lua block via startup_on module.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_startup_on_headless_status.txt"
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

local function main()
  local path = PKG .. "/modules/startup_on.lua"
  local chunk, err = loadfile(path)
  if not chunk then
    fail("load startup_on: " .. tostring(err))
    return
  end
  PTT = { _script_root = PKG .. "/", VERSION = "2.2.3" }
  chunk()
  local S = PTT.startup_on
  if not S then
    fail("module missing")
    return
  end

  local tmp = "/tmp/ptt_startup_on_headless_" .. tostring(os.time())
  os.execute('mkdir -p "' .. tmp .. '/Scripts"')
  local ptt_main = PKG .. "/ProjectTimeTracker.lua"
  local preexisting = "-- other startup stuff\nreaper.ShowConsoleMsg('hi')\n"
  local startup = S.startup_file(tmp)
  local wf = io.open(startup, "w")
  if not wf then
    fail("cannot write temp startup")
    return
  end
  wf:write(preexisting)
  wf:close()

  local eok, ereason = S.enable({ resource_path = tmp, ptt_path = ptt_main })
  if not eok or ereason ~= "enabled" then
    fail("enable: " .. tostring(ereason))
    return
  end
  local body = S.read_file(startup)
  if not S.is_enabled(body) then
    fail("not enabled after enable")
    return
  end
  if not body:find("other startup stuff", 1, true) then
    fail("lost preexisting")
    return
  end
  if not body:find("ProjectTimeTracker.lua", 1, true) then
    fail("missing ptt path in block")
    return
  end

  -- Resource path from live REAPER must resolve
  local res = reaper.GetResourcePath and reaper.GetResourcePath() or ""
  if res == "" then
    fail("GetResourcePath empty")
    return
  end
  local live_startup = S.startup_file(res)
  if not live_startup or not live_startup:find("__startup.lua", 1, true) then
    fail("live startup path bad: " .. tostring(live_startup))
    return
  end

  -- Round-trip on live resource with backup (safe)
  local bak = live_startup .. ".ptt_test_bak"
  local live_before = S.read_file(live_startup)
  do
    local bf = io.open(bak, "wb")
    if bf then bf:write(live_before); bf:close() end
  end
  local lok, lreason = S.enable({ resource_path = res, ptt_path = ptt_main })
  if not lok then
    -- restore
    S.write_file(live_startup, live_before)
    fail("live enable: " .. tostring(lreason))
    return
  end
  local live_mid = S.read_file(live_startup)
  if not S.is_enabled(live_mid) then
    S.write_file(live_startup, live_before)
    fail("live not enabled")
    return
  end
  local dok, dreason = S.disable({ resource_path = res })
  if not dok then
    S.write_file(live_startup, live_before)
    fail("live disable: " .. tostring(dreason))
    return
  end
  local live_after = S.read_file(live_startup)
  -- restore exact backup so we don't leave test residue if strip differed
  S.write_file(live_startup, live_before)
  os.remove(bak)

  if S.is_enabled(live_after) then
    fail("live still enabled after disable")
    return
  end

  local tok, treason = S.disable({ resource_path = tmp })
  if not tok or treason ~= "disabled" then
    fail("temp disable: " .. tostring(treason))
    return
  end
  if S.is_enabled(S.read_file(startup)) then
    fail("temp still enabled")
    return
  end

  ok(string.format(
    "startup_on enable/disable OK (live_res=%s reason=%s)",
    res, tostring(lreason)))
end

main()
reaper.defer(function() reaper.Main_OnCommand(40004, 0) end) -- File: Quit
