-- test_office_opt_headless.lua
-- Headless REAPER: ExtState opt-out via live reaper API + mirror/notes gates.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_office_opt_headless_status.txt"
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
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.8" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "office_opt", "mirror", "notes_ui", "bootstrap",
  }
  for _, m in ipairs(mods) do
    local path = PKG .. "/modules/" .. m .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("load " .. m .. ": " .. tostring(err)) end
    chunk()
  end
end

local function real_fs()
  return {
    read_all = function(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    write_all = function(path, data)
      local f, err = io.open(path, "wb")
      if not f then return false, err or "write failed" end
      f:write(data)
      f:close()
      return true
    end,
    rename = function(a, b)
      local ok_r, err = os.rename(a, b)
      if ok_r then return true end
      return false, err or "rename failed"
    end,
    remove = function(path)
      os.remove(path)
      return true
    end,
    mkdir_p = function(dir)
      os.execute('mkdir -p "' .. tostring(dir):gsub('"', '\\"') .. '"')
      return true
    end,
  }
end

local function main()
  local loaded, err = pcall(load_modules)
  if not loaded then
    fail("module load: " .. tostring(err))
    return
  end
  if not (PTT.office_opt and PTT.mirror and PTT.notes_ui) then
    fail("office_opt/mirror/notes_ui missing")
    return
  end

  -- Use live GetProjExtState/SetProjExtState on the current project (no Save dialog).
  PTT.office_opt.set_opted_out(reaper, false)
  if PTT.office_opt.is_opted_out(reaper) then
    fail("expected clear after set false")
    return
  end

  local on = PTT.office_opt.toggle(reaper)
  if not on or not PTT.office_opt.is_opted_out(reaper) then
    fail("toggle on failed")
    return
  end

  local ret, val = reaper.GetProjExtState(0, "ProjectTimeTracker", "office_opt_out")
  if ret ~= 1 or val ~= "1" then
    fail("ExtState not set: ret=" .. tostring(ret) .. " val=" .. tostring(val))
    return
  end

  local tmp = "/tmp/ptt_office_opt_hl_" .. tostring(os.time())
  os.execute('mkdir -p "' .. tmp .. '/local" "' .. tmp .. '/central"')
  local src = tmp .. "/local/GUID-OPT.timelog.jsonl"
  local dest = tmp .. "/central/GUID-OPT.timelog.jsonl"
  local f = assert(io.open(src, "w"))
  f:write('{"event":"a"}\n')
  f:close()
  local fs = real_fs()

  local ctx = {
    cfg = {
      mirror_enabled = true,
      central_timelogs_dir = tmp .. "/central",
      mirror_interval_s = 300,
      notes_ui_base_url = "http://127.0.0.1:3001",
      notes_auto_open = true,
    },
    ident = { guid = "GUID-OPT", saved = true },
    writer = { path = src },
    reaper = reaper,
    last_mirror_ts = 0,
    now = function() return os.time() end,
    notes_last_open_ts = {},
  }

  PTT.mirror.maybe_mirror(ctx, { force = true, fs = fs, now = os.time() })
  if io.open(dest, "r") then
    fail("mirror should skip when opted out")
    return
  end

  local ok_h, reason_h = PTT.mirror.maybe_hydrate(ctx, { fs = fs })
  if ok_h or reason_h ~= "office_opt_out" then
    fail("hydrate expected office_opt_out, got " .. tostring(reason_h))
    return
  end

  local ok_n, reason_n = PTT.notes_ui.maybe_auto_open(ctx, {
    http_get = function() return '{"blocks":1,"missing":1}' end,
    open_fn = function() error("must not open when opted out") end,
  })
  if ok_n or reason_n ~= "office_opt_out" then
    fail("notes expected office_opt_out, got " .. tostring(reason_n))
    return
  end

  local off = PTT.office_opt.toggle(reaper)
  if off or PTT.office_opt.is_opted_out(reaper) then
    fail("toggle off failed")
    return
  end

  ctx.last_mirror_ts = 0
  PTT.mirror.maybe_mirror(ctx, { force = true, fs = fs, now = os.time() + 1 })
  local df = io.open(dest, "r")
  if not df then
    fail("mirror should run after opt-out cleared")
    return
  end
  df:close()

  ok("office opt-out headless OK (ExtState toggle + mirror/hydrate/notes gates)")
end

local ran, err = pcall(main)
if not ran then
  fail("pcall: " .. tostring(err))
end

reaper.defer(function() end)
os.exit(0)
