-- test_mirror_mkdir_headless.lua
-- Headless: (1) unsaved must not mirror-warn (2) saved mirrors to writable central
-- (3) Mac path adaptation from /mnt/cube config.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_mirror_mkdir_headless_status.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local CENTRAL = os.getenv("PTT_CENTRAL")
  or "/mnt/cube/01_Projekte/_Temp/ptt_e2e/timelogs"

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
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.10" }
  for _, m in ipairs({
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "office_opt", "mirror", "notes_ui", "bootstrap",
  }) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
end

local function main()
  local loaded, err = pcall(load_modules)
  if not loaded then
    fail("load: " .. tostring(err))
    return
  end

  -- Mac adaptation of shared Linux config path
  local adapted = PTT.config.adapt_central_dir(
    "/mnt/cube/01_Projekte/_Temp/ptt_e2e/timelogs", "OSX64")
  if adapted ~= "/Volumes/PRODUKTION/01_Projekte/_Temp/ptt_e2e/timelogs" then
    fail("mac adapt got " .. tostring(adapted))
    return
  end

  local msgs = {}
  local fake_reaper = {
    ShowConsoleMsg = function(s) msgs[#msgs + 1] = s end,
    GetOS = function() return "Other" end,
    RecursiveCreateDirectory = reaper.RecursiveCreateDirectory,
  }

  -- 1) Unsaved: must not attempt mirror / warn
  local tmp = "/tmp/ptt_mkdir_hl_" .. tostring(os.time())
  os.execute('mkdir -p "' .. tmp .. '"')
  local src = tmp .. "/local.timelog.jsonl"
  local f = assert(io.open(src, "w")); f:write('{"event":"a"}\n'); f:close()
  PTT.mirror.maybe_mirror({
    cfg = { mirror_enabled = true, central_timelogs_dir = CENTRAL, mirror_interval_s = 1 },
    ident = { guid = "UNSAVED-GUID", saved = false },
    writer = { path = src },
    reaper = fake_reaper,
    last_mirror_ts = 0,
  }, { force = true, now = 1000 })
  for _, m in ipairs(msgs) do
    if m:find("mkdir failed", 1, true) then
      fail("unsaved produced mkdir warning")
      return
    end
  end

  -- 2) Saved + writable central: mirror must succeed without warning
  msgs = {}
  local guid = "HEADLESS-MKDIR-" .. tostring(os.time())
  local dest = CENTRAL .. "/" .. guid .. ".timelog.jsonl"
  os.remove(dest)
  PTT.mirror.maybe_mirror({
    cfg = { mirror_enabled = true, central_timelogs_dir = CENTRAL, mirror_interval_s = 1 },
    ident = { guid = guid, saved = true },
    writer = { path = src },
    reaper = fake_reaper,
    last_mirror_ts = 0,
  }, { force = true, now = 2000 })
  for _, m in ipairs(msgs) do
    if m:find("mirror warning", 1, true) then
      fail("saved mirror warned: " .. m)
      return
    end
  end
  local body = io.open(dest, "r")
  if not body then
    fail("central file missing after mirror: " .. dest)
    return
  end
  body:close()
  os.remove(dest)

  -- 3) Saved + impossible central path: warning must include dest path
  msgs = {}
  PTT.mirror.maybe_mirror({
    cfg = {
      mirror_enabled = true,
      central_timelogs_dir = "/nonexistent/ptt_timelogs_xyz",
      mirror_interval_s = 1,
    },
    ident = { guid = "BADPATH", saved = true },
    writer = { path = src },
    reaper = fake_reaper,
    last_mirror_ts = 0,
  }, { force = true, now = 3000 })
  local saw = false
  for _, m in ipairs(msgs) do
    if m:find("mkdir failed", 1, true) and m:find("BADPATH", 1, true) then
      saw = true
    end
  end
  if not saw then
    fail("expected mkdir warning with dest path, msgs=" .. table.concat(msgs, " | "))
    return
  end

  ok("mirror mkdir headless OK (unsaved silent, saved ok, bad path warns with dest)")
end

local ran, err = pcall(main)
if not ran then
  fail("pcall: " .. tostring(err))
end
reaper.defer(function() end)
os.exit(0)
