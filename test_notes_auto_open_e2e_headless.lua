-- test_notes_auto_open_e2e_headless.lua
-- Full path: load studio config → status against live DispoDisco (fresh file) → auto-open.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_notes_auto_open_e2e_status.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local CFG = os.getenv("PTT_CONFIG")
  or "/mnt/cube/01_Projekte/_Temp/ptt_e2e/ptt_config.json"
local OFFICE = os.getenv("NOTES_UI_BASE") or "http://192.168.203.101:3001"
local TIMELOGS = os.getenv("PTT_CENTRAL")
  or "/mnt/cube/01_Projekte/_Temp/ptt_e2e/timelogs"
local FIXTURE = os.getenv("PTT_BLOCKS_FIXTURE")
  or "/home/doktorlinux/DispoDisco-Server/tests/fixtures/blocks.timelog.jsonl"

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
  PTT = { _script_root = PKG .. "/", VERSION = "2.1.11" }
  for _, m in ipairs({
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "office_opt", "mirror", "notes_ui", "bootstrap",
  }) do
    assert(loadfile(PKG .. "/modules/" .. m .. ".lua"))()
  end
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function main()
  local loaded, err = pcall(load_modules)
  if not loaded then
    fail("load: " .. tostring(err))
    return
  end

  reaper.SetExtState("ProjectTimeTracker", "ptt_config_path", CFG, true)
  local cfg = PTT.config.load_from_paths({ CFG })
  if (cfg.notes_ui_base_url or "") == "" then
    fail("config missing notes_ui_base_url — file=" .. CFG)
    return
  end
  -- Prefer explicit OFFICE for this host; config may point at LAN IP
  local base = OFFICE
  cfg.notes_ui_base_url = base
  cfg.notes_auto_open = true

  local guid = "E2E-NOTES-" .. tostring(os.time())
  local src_fix = read_all(FIXTURE)
  if not src_fix then
    fail("missing fixture " .. FIXTURE)
    return
  end
  local body = src_fix:gsub("GUID%-BLOCKS%-001", guid)
  local dest = TIMELOGS .. "/" .. guid .. ".timelog.jsonl"
  local out = assert(io.open(dest, "w"))
  out:write(body)
  out:close()

  -- Live HTTP as PTT does (curl), before any manual office refresh
  local status_url = PTT.notes_ui.status_url(base, guid, "from=2026-10-01&to=2026-10-31")
  local raw = PTT.notes_ui.default_http_get(status_url, 3)
  if not raw or not raw:find('"missing"') then
    fail("status http failed: url=" .. status_url .. " body=" .. tostring(raw))
    return
  end
  local missing = PTT.notes_ui.fetch_missing(status_url, PTT.notes_ui.default_http_get, 3)
  if missing == nil or missing < 1 then
    fail("expected missing>0 got " .. tostring(missing) .. " raw=" .. tostring(raw))
    return
  end

  local opened = {}
  local msgs = {}
  local ctx = {
    cfg = cfg,
    ident = { guid = guid, saved = true },
    reaper = {
      ShowConsoleMsg = function(s) msgs[#msgs + 1] = s end,
      GetOS = function() return "Other" end,
    },
    now = function() return os.time() end,
    notes_last_open_ts = {},
  }
  local did, reason = PTT.notes_ui.maybe_auto_open(ctx, {
    qs = "from=2026-10-01&to=2026-10-31",
    open_fn = function(url) opened[#opened + 1] = url end,
  })
  if not did or reason ~= "opened" then
    fail("auto_open failed: " .. tostring(reason) .. " msgs=" .. table.concat(msgs, "|"))
    return
  end
  if not opened[1] or not opened[1]:find("src=reaper", 1, true) or not opened[1]:find(guid, 1, true) then
    fail("bad open url: " .. tostring(opened[1]))
    return
  end

  -- Save a note via office POST path using curl
  local bid = "recording:rec_a:2026-10-01T08:25:00"
  local post_cmd = string.format(
    "curl -s -m 5 -o /dev/null -w '%%{http_code}' -X POST %q -d %q",
    base .. "/projects/" .. guid .. "/notes",
    "block_id=" .. bid .. "&text=E2E+auto+note&from=2026-10-01&to=2026-10-31"
  )
  local ph = io.popen(post_cmd)
  local code = ph and ph:read("*a") or ""
  if ph then ph:close() end
  if code ~= "303" and code ~= "200" then
    fail("note save http=" .. tostring(code))
    return
  end

  local missing2 = PTT.notes_ui.fetch_missing(status_url, PTT.notes_ui.default_http_get, 3)
  if missing2 == nil or missing2 ~= missing - 1 then
    fail("after save missing expected " .. tostring(missing - 1) .. " got " .. tostring(missing2))
    return
  end

  os.remove(dest)
  os.remove(TIMELOGS .. "/" .. guid .. ".notes.jsonl")

  ok(string.format(
    "notes auto-open e2e OK base=%s guid=%s missing=%s→%s url=%s",
    base, guid, tostring(missing), tostring(missing2), opened[1]
  ))
end

local ran, err = pcall(main)
if not ran then
  fail("pcall: " .. tostring(err))
end
reaper.defer(function() end)
os.exit(0)
