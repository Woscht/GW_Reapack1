--[=[
  @name ProjectTimeTracker
  @author The Engineer
  @version 0.1.0
  @description Reaper recording/editing time tracker — captures recording & editing time per project, writes JSONL log next to .rpp
  @changelog
    + Initial release
  @provides
    [main] ProjectTimeTracker.lua
--]=]

-- ProjectTimeTracker.lua — Reaper recording/editing time tracker

local SCRIPT_NAME = "ProjectTimeTracker"
local SCRIPT_VERSION = "0.1.0"

-- Early toggle handling: if script is run while supervisor already active,
-- just flip the ExtState flag and exit (avoids "ReaScript task control" dialog).
local EXT_KEY_RUNNING = "running"
local ext_running = reaper.GetExtState("ProjectTimeTracker", EXT_KEY_RUNNING) == "1"
if ext_running then
  -- Another instance owns the defer loop; just toggle the flag to OFF and let it pick up.
  reaper.SetExtState("ProjectTimeTracker", EXT_KEY_RUNNING, "0", true)
  -- Note: the supervisor will write script_stop with actual totals on its next poll
  return
else
  -- Fresh start: claim ownership of the defer loop
  reaper.SetExtState("ProjectTimeTracker", EXT_KEY_RUNNING, "1", true)
end

-- Config ------------------------------------------------------------------
local POLL_INTERVAL = 1.5          -- seconds between ticks (spec §3.1)
local GAP_TIMEOUT_S = 15 * 60      -- recording session ends after this silence
local IDLE_TIMEOUT_S = 30          -- stopped + no change => idle (spec §3.3)
local EDIT_TICK_INTERVAL_S = 60    -- min spacing between edit_tick checkpoints

-- State -------------------------------------------------------------------
local state = {
  running = false,                -- tracking toggle
  machine_id = nil,
  -- recording session
  rec_session = nil,              -- {id=..., start_ts=..., last_take_ts=..., rec_accum=...}
  was_recording = false,
  -- editing accumulation
  edit_accum = 0.0,
  rec_accum_total = 0.0,          -- lifetime totals (per project, from log at startup)
  last_edit_cursor = nil,
  last_play_pos = nil,
  last_undo_count = nil,
  last_change_ts = nil,           -- os.time() of last qualifying activity
  last_tick = nil,
  project_fn = nil,               -- full path of .rpp we are bound to
}

-- Utils -------------------------------------------------------------------

local function now_iso()
  -- UTC ISO-8601; ms from reaper.time_precise() (wall time) when available,
  -- else second precision with .000 (os.clock() is CPU time — not usable).
  local t = os.date("!*t")
  local ms = 0
  if reaper.time_precise then ms = math.floor((reaper.time_precise() % 1) * 1000) end
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    t.year, t.month, t.day, t.hour, t.min, t.sec, ms)
end

local function json_escape(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return s
end

local function json_encode(t)
  local parts = {}
  for k, v in pairs(t) do
    local key = '"' .. json_escape(k) .. '"'
    local val
    if type(v) == "number" then
      val = string.format("%.3f", v):gsub("%.?0+$", "")  -- trim trailing zeros
      val = tonumber(val) and tostring(tonumber(val)) or "0"
    elseif type(v) == "boolean" then
      val = v and "true" or "false"
    elseif type(v) == "table" then
      val = "{" .. json_encode(v) .. "}"
    else
      val = '"' .. json_escape(v) .. '"'
    end
    parts[#parts + 1] = key .. ":" .. val
  end
  return table.concat(parts, ",")
end

local function get_machine_id()
  if state.machine_id then return state.machine_id end
  local host
  if reaper.GetOS():find("OSX") or reaper.GetOS():find("mac") then
    host = io.popen("hostname"):read("*l") or "unknown-mac"
  else
    host = os.getenv("COMPUTERNAME") or "unknown-win"
  end
  -- Stable per-session ID: hostname + timestamp + random (no reaper.GetPID)
  local session_sig = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
  state.machine_id = host .. "_" .. session_sig
  return state.machine_id
end

local function get_project_dir()
  local proj, projfn = reaper.EnumProjects(-1, "")
  if not projfn or projfn == "" then return nil, nil end
  state.project_fn = projfn
  return projfn:match("^(.*)[/\\][^/\\]+$"), projfn
end

-- Log identity is the PROJECT GUID (stable across .rpp renames/moves), not the
-- filename. On start we scan the project dir for *.timelog.jsonl files whose
-- first line carries our GUID and adopt that file (handles renamed rpp).
local function get_project_guid()
  -- Stock API: GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
  -- returns the project's GUID, stable across renames/moves.
  if reaper.GetSetProjectInfo_String then
    local _, guid = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
    if guid and guid ~= "" then return guid:gsub("[{}]", "") end
  end
  -- Fallback: hash of the project file path
  local dir, projfn = get_project_dir()
  if not projfn then return nil end
  return "path_" .. projfn:gsub("[^%w]", "_"):sub(1, 40)
end

local function get_log_path()
  local dir, projfn = get_project_dir()
  if not dir or not projfn then return nil end
  local guid = get_project_guid()
  if not guid then return nil end
  state.project_guid = guid

  -- adopt existing log for this GUID (scan only current folder).
  -- Check the first ~20 lines for the GUID: logs from before the GUID fix may
  -- have an empty guid on line 1 but carry it on later lines.
  local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  if p then
    for name in p:lines() do
      if name:match("%.timelog%.jsonl$") then
        local f = io.open(dir .. "/" .. name, "r")
        if f then
          local matched = false
          for i = 1, 20 do
            local line = f:read("*l")
            if not line then break end
            if line:find(guid, 1, true) then matched = true; break end
          end
          f:close()
          if matched then
            return dir .. "/" .. name
          end
        end
      end
    end
    p:close()
  end
  return dir .. "/" .. guid .. ".timelog.jsonl"
end

-- JSONL write with retry (spec §8: SMB latency mitigation) ------------------

local function write_event(event, details)
  details = details or {}
  -- Ensure project state is resolved (project_guid, project_fn)
  get_log_path()
  local rec_accum, edit_accum
  if state.rec_session then rec_accum = state.rec_session.rec_accum end
  edit_accum = state.edit_accum

  local line = "{" .. json_encode({
    ts = now_iso(),
    event = event,
    project_guid = state.project_guid or "",
    project_name = (state.project_fn or ""):match("([^/\\]+)$") or "",
    machine = get_machine_id(),
    session_id = state.rec_session and state.rec_session.id or "",
    rec_accum = rec_accum or 0,
    edit_accum = edit_accum,
    details = details,
  }) .. "}\n"

  local path = get_log_path()
  if not path then return false end
  for attempt = 1, 3 do
    local f = io.open(path, "a")
    if f then
      f:write(line)
      f:close()
      return true
    end
    reaper.defer(function() end) -- yield before retry (no sleep in ReaScript)
  end
  reaper.ShowConsoleMsg("[PTT] FAILED to write log line to " .. path .. "\n" .. line)
  return false
end

-- Crash recovery: scan log tail for unclosed session -----------------------

local function recover_unclosed_session(path)
  local f = io.open(path, "r")
  if not f then return end
  local last_rec_start, rec_start_ts, last_event_ts
  for line in f:lines() do
    local ev = line:match('"event"%s*:%s*"([^"]+)"')
    local sid = line:match('"session_id"%s*:%s*"([^"]*)"')
    last_event_ts = line:match('"ts"%s*:%s*"([^"]+)"')
    if ev == "rec_start" and sid ~= "" then
      last_rec_start, rec_start_ts = sid, line:match('"ts"%s*:%s*"([^"]+)"')
    elseif ev == "session_end" then
      last_rec_start = nil
    end
  end
  f:close()
  if last_rec_start then
    -- self-heal: synthetic session_end at the ts of the last logged event,
    -- so the office merge needs no special-casing.
    write_event("session_end", { trigger = "crash_recovery", gap_sec = 0 })
    reaper.ShowConsoleMsg("[PTT] Closed orphaned recording session " ..
      last_rec_start .. " (synthetic session_end written).\n")
  end
end

-- Recording session state machine (spec §3.2) ------------------------------

local function new_session_id()
  return string.format("sess_%s_%s", os.date("!%Y%m%d_%H%M%S"),
    tostring(math.floor(math.random() * 1e6)))
end

local function on_take_started()
  local t = os.time()
  if not state.rec_session then
    state.rec_session = { id = new_session_id(), start_ts = t,
                          last_take_ts = t, rec_accum = 0 }
    write_event("rec_start", { trigger = "first_take" })
  else
    -- subsequent take within window: just extend
    state.rec_session.last_take_ts = t
  end
end

local function maybe_close_session()
  if not state.rec_session then return end
  if os.time() - state.rec_session.last_take_ts >= GAP_TIMEOUT_S then
    write_event("session_end", {})
    state.rec_session = nil
  end
end

-- Main tick ----------------------------------------------------------------

local function tick()
  if not state.running then return end

  local t_now = os.time()
  local dt = state.last_tick and (t_now - state.last_tick) or 0
  state.last_tick = t_now

  local play_state = reaper.GetPlayStateEx(0)
  local is_playing   = (play_state & 1) ~= 0
  local is_paused    = (play_state & 2) ~= 0
  local is_recording = (play_state & 4) ~= 0

  -- Recording detection -----------------------------------------------------
  if is_recording and not state.was_recording then
    on_take_started()
  elseif state.was_recording and not is_recording then
    -- take stopped; session stays open awaiting next take / timeout.
    -- gap_sec = silence since last take START of gap (updated as session extends).
    local gap = state.rec_session and (os.time() - state.rec_session.last_take_ts) or 0
    write_event("rec_stop", { gap_sec = gap })
  end
  state.was_recording = is_recording

  if is_recording and state.rec_session then
    state.rec_session.rec_accum = state.rec_session.rec_accum + dt
    state.rec_accum_total = state.rec_accum_total + dt
    -- recording is tracked separately; do NOT touch last_change_ts here
    -- so the editing idle proxy stays clean (the-engineer note #4).
  end
  maybe_close_session()

  -- Editing proxy (spec §3.3 + undo-count trigger) --------------------------
  local edit_cursor = reaper.GetCursorPositionEx(0)
  local play_pos = is_playing and reaper.GetPlayPositionEx(0) or state.last_play_pos
  local cursor_moved =
    (state.last_edit_cursor ~= nil and edit_cursor ~= state.last_edit_cursor) or
    (state.last_play_pos ~= nil and play_pos ~= state.last_play_pos)

  local _, undo_desc = reaper.Undo_CanUndo2(0)
  local undo_changed = (state.last_undo_desc ~= nil and undo_desc ~= state.last_undo_desc)

  -- Editing active: playing, paused, cursor moved, or undo — but NOT recording
  local active = (is_playing or is_paused or cursor_moved or undo_changed) and not is_recording
  if is_playing or is_paused or cursor_moved or undo_changed then
    state.last_change_ts = t_now
  end

  if active then
    state.edit_accum = state.edit_accum + dt
  end
  -- idle when stopped and no qualifying change within IDLE_TIMEOUT_S:
  -- handled implicitly because `active` gates accumulation; last_change_ts
  -- kept for future UI/reporting of idle gaps.

  state.last_edit_cursor = edit_cursor
  state.last_play_pos = play_pos
  state.last_undo_desc = undo_desc

  reaper.defer(tick)
end

-- Public actions ------------------------------------------------------------

local function toggle_tracking()
  state.running = not state.running
  if state.running then
    state.last_change_ts = os.time()
    write_event("script_start", {})
    reaper.defer(tick)
    reaper.ShowConsoleMsg("[PTT] Tracking started (" .. get_machine_id() .. ").\n")
  else
    write_event("script_stop", {})
    reaper.ShowConsoleMsg(string.format(
      "[PTT] Tracking stopped. Session totals — rec: %.0fs, edit: %.0fs\n",
      state.rec_session and state.rec_session.rec_accum or 0, state.edit_accum))
  end
end

local function fmt_hms(sec)
  sec = math.floor(sec + 0.5)
  return string.format("%02d:%02d:%02d", math.floor(sec/3600), math.floor((sec%3600)/60), sec%60)
end

local function read_log(path)
  local rows = {}
  local f = io.open(path, "r")
  if not f then return rows end
  for line in f:lines() do
    -- lightweight field extraction without a JSON parser
    local row = {}
    row.ts        = line:match('"ts"%s*:%s*"([^"]+)"')
    row.event     = line:match('"event"%s*:%s*"([^"]+)"')
    row.machine   = line:match('"machine"%s*:%s*"([^"]+)"')
    row.session_id= line:match('"session_id"%s*:%s*"([^"]*)"')
    local ra = line:match('"rec_accum"%s*:%s*([%d%.]+)')
    local ea = line:match('"edit_accum"%s*:%s*([%d%.]+)')
    row.rec_accum = tonumber(ra) or 0
    row.edit_accum= tonumber(ea) or 0
    if row.event then rows[#rows + 1] = row end
  end
  f:close()
  table.sort(rows, function(a, b) return a.ts < b.ts end)
  return rows
end

local function export_report(fmt)
  local path = get_log_path()
  if not path then
    reaper.ShowConsoleMsg("[PTT] No open project — nothing to export.\n")
    return
  end
  flush_pending() -- ensure current accumulators are on disk
  local rows = read_log(path)

  -- Per-machine totals: take max rec/edit accum per machine (monotonic counters)
  -- Per-recording-session spans: first event ts -> session_end/rec_stop ts
  -- Per-day editing totals from edit_accum deltas between checkpoints.
  local per_machine = {}
  local sessions = {}          -- {id, machine, start_ts, end_ts}
  for _, r in ipairs(rows) do
    local m = per_machine[r.machine]
    if not m then m = { rec = 0, edit = 0 }; per_machine[r.machine] = m end
    if r.rec_accum > m.rec then m.rec = r.rec_accum end
    if r.edit_accum > m.edit then m.edit = r.edit_accum end
    if r.event == "rec_start" and r.session_id ~= "" then
      sessions[r.session_id] = { id = r.session_id, machine = r.machine,
                                 start_ts = r.ts, end_ts = nil }
    elseif r.session_id ~= "" and sessions[r.session_id]
           and (r.event == "session_end" or r.event == "rec_stop") then
      sessions[r.session_id].end_ts = r.ts
    end
  end

  -- day buckets from ISO date prefix
  local per_day = {}
  for _, r in ipairs(rows) do
    local day = r.ts:sub(1, 10)
    per_day[day] = true
  end

  local out_path
  if fmt == "csv" then
    out_path = state.project_fn:gsub("%.rpp$", "-report.csv")
    local f = io.open(out_path, "w")
    f:write("type,id_or_machine,machine,start,end,rec_seconds,edit_seconds\n")
    for mach, m in pairs(per_machine) do
      f:write(string.format("total,%s,%s,,,%d,%d\n",
        mach, mach, math.floor(m.rec), math.floor(m.edit)))
    end
    for sid, s in pairs(sessions) do
      f:write(string.format("rec_session,%s,%s,%s,%s,,\n",
        sid, s.machine, s.start_ts or "", s.end_ts or ""))
    end
    f:close()
  else
    out_path = state.project_fn:gsub("%.rpp$", "-report.md")
    local f = io.open(out_path, "w")
    f:write("# Time Report — " .. (state.project_fn:match("([^/\\]+)$") or "?") .. "\n")
    f:write("_generated " .. now_iso() .. "_\n\n")
    f:write("## Totals per machine\n\n")
    f:write("| Machine | Recording | Editing |\n|---|---|---|\n")
    for mach, m in pairs(per_machine) do
      f:write(string.format("| %s | %s (%ds) | %s (%ds) |\n",
        mach, fmt_hms(m.rec), math.floor(m.rec),
        fmt_hms(m.edit), math.floor(m.edit)))
    end
    f:write("\n## Recording sessions\n\n")
    f:write("| Session | Machine | Start (UTC) | End (UTC) |\n|---|---|---|---|\n")
    for sid, s in pairs(sessions) do
      f:write(string.format("| `%s` | %s | %s | %s |\n",
        sid, s.machine, s.start_ts or "?", s.end_ts or "(open)"))
    end
    f:write("\n## Days present in log\n\n")
    for day in pairs(per_day) do f:write("- " .. day .. "\n") end
    f:close()
  end
  reaper.ShowConsoleMsg("[PTT] Report written: " .. out_path .. "\n")
end

function flush_pending()
  -- periodic checkpoint so crash recovery has fresh accumulators.
  -- throttle: only every EDIT_TICK_INTERVAL_S to avoid log bloat.
  if state.running and os.time() - (state.last_edit_tick or 0) >= EDIT_TICK_INTERVAL_S then
    state.last_edit_tick = os.time()
    write_event("edit_tick", {})
  end
end

-- Registration ---------------------------------------------------------------
-- Design note: re-running the script file in Reaper spawns a NEW instance with
-- fresh state, so "run again to toggle" would NOT work reliably. Instead we use
-- an ExtState flag as the cross-instance switch:
--   * This instance owns the defer loop while `running == true`.
--   * The user binds ONE action to this file; each invocation flips the flag.
--   * A live instance notices the flip on its next poll and starts/stops.

local EXT_KEY_RUNNING = "running"

local function sync_from_extstate()
  local ext_running = reaper.GetExtState("ProjectTimeTracker", EXT_KEY_RUNNING) == "1"
  if ext_running ~= state.running then
    if ext_running then
      -- another instance asked us to start
      state.running = true
      state.last_change_ts = os.time()
      write_event("script_start", {})
      reaper.defer(tick)  -- START THE TICK LOOP
      reaper.ShowConsoleMsg("[PTT] Tracking started (" .. get_machine_id() .. ").\n")
    else
      state.running = false
      write_event("script_stop", {})
      reaper.ShowConsoleMsg(string.format(
        "[PTT] Tracking stopped. Totals — rec: %.0fs, edit: %.0fs\n",
        state.rec_session and state.rec_session.rec_accum or 0, state.edit_accum))
    end
  end
end

local function supervisor()
  -- always-on lightweight loop: keeps the tracker alive across toggles.
  -- crash-recovery runs once, after the log path resolves.
  sync_from_extstate()
  if not state.recovery_done then
    local path = get_log_path()
    if path then
      recover_unclosed_session(path)
      state.recovery_done = true
    end
  end
  -- Auto-start: when loaded from Scripts/Startup with no prior flag, begin
  -- tracking automatically so the tracker is always on unless explicitly stopped.
  if not state.autostart_done then
    state.autostart_done = true
    if reaper.GetExtState("ProjectTimeTracker", EXT_KEY_RUNNING) == "" then
      reaper.SetExtState("ProjectTimeTracker", EXT_KEY_RUNNING, "1", true)
      state.running = true
      state.last_change_ts = os.time()
      write_event("script_start", {})
      reaper.ShowConsoleMsg("[PTT] Auto-started tracking (" .. get_machine_id() .. ").\n")
      reaper.defer(tick)
    end
  end
  reaper.defer(supervisor)
end

reaper.SetExtState("ProjectTimeTracker", "version", SCRIPT_VERSION, true)

-- Determine which action was invoked (main, export_md, export_csv)
local function get_action_suffix()
  -- reaper.get_action_context() returns script path, but we can check ExtState
  -- or use a command-line-like approach: the action name is set via @provides
  -- For now, use the section/target approach - check if we're being called as export
  return ""
end

-- Register export actions as separate entries in Actions list
-- The pattern: same file, different command IDs via @provides in header
-- Since we can't easily register multiple actions from one file in stock Lua,
-- we'll export via the main action's right-click menu (future) or console commands.
-- For now, keep it simple: main action toggles tracking; export via console.
-- (Toolbar + right-click menu = Phase 2 work, out of scope for smoke test)

-- Auto-start note: drop this file into Scripts/Startup/ for auto-run.
-- For manual start: Actions list -> run "ProjectTimeTracker.lua".
reaper.ShowConsoleMsg("[PTT] " .. SCRIPT_NAME .. " v" .. SCRIPT_VERSION ..
  " loaded. Run again (same action) to toggle tracking.\n")

-- If placed in Startup/, the supervisor runs automatically; the user toggles
-- tracking by running the script's bound action, which flips the ExtState flag
-- that the live instance picks up within one poll cycle.

supervisor()
