PTT = PTT or {}
PTT.bootstrap = {}
local M = PTT.bootstrap

local EXT_NS = "ProjectTimeTracker"
local EXT_RUNNING = "running"

local function script_dir_from_debug()
  -- filled by entry via PTT._script_root
  return PTT._script_root or ""
end

local function reaper_identity(reaper)
  return PTT.identity.snapshot({
    get_guid = function()
      -- Stock PROJECT_GUID is empty on some REAPER/Linux builds; fall back to
      -- a stable ProjExtState id so logs keep identity across Save As / versions.
      local ok, guid = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
      if ok and guid and guid ~= "" then return guid end
      local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
      if ret == 1 and stored and stored ~= "" then return stored end
      local fresh = reaper.genGuid and reaper.genGuid("") or string.format("%d-%d", os.time(), math.random(1e9))
      reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", fresh)
      return fresh
    end,
    get_project_path = function()
      -- GetProjectPath() returns the media/record path (.../Media), NOT the .rpp dir.
      local _, fn = reaper.EnumProjects(-1, "")
      if fn and fn ~= "" then
        local dir = fn:match("^(.*)[/\\][^/\\]+$")
        if dir and dir ~= "" then return dir end
      end
      local path = reaper.GetProjectPath("") or ""
      path = path:gsub("[/\\]Media[/\\]?$", ""):gsub("[/\\]+$", "")
      return path
    end,
    get_project_name = function()
      local _, fn = reaper.EnumProjects(-1, "")
      if not fn or fn == "" then return "" end
      return fn:match("([^/\\]+)$") or fn
    end,
    is_untitled = function()
      local _, fn = reaper.EnumProjects(-1, "")
      return not fn or fn == ""
    end,
  })
end

local function sel_fingerprint(reaper)
  local parts = {}
  local tc = reaper.CountTracks(0) or 0
  for i = 0, tc - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr and reaper.IsTrackSelected(tr) then
      parts[#parts + 1] = "T" .. i
    end
  end
  local ic = reaper.CountSelectedMediaItems(0) or 0
  for i = 0, ic - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    if it then
      local guid
      if reaper.BR_GetMediaItemGUID then
        guid = reaper.BR_GetMediaItemGUID(it)
      end
      if not guid or guid == "" then
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION") or 0
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH") or 0
        guid = string.format("%.5f:%.5f", pos, len)
      end
      parts[#parts + 1] = guid
    end
  end
  return table.concat(parts, ",")
end

local function sample(reaper, prev_activity)
  local play_state = reaper.GetPlayStateEx(0) or 0
  local edit_cursor = reaper.GetCursorPositionEx(0) or 0
  local play_cursor = reaper.GetPlayPositionEx(0) or 0
  local is_dirty = (reaper.IsProjectDirty(0) or 0) ~= 0
  local undo_count = 0
  if reaper.Undo_CanUndo2 then
    -- approximate: use project dirty gen if available
    undo_count = reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0) or 0
  elseif reaper.GetProjectStateChangeCount then
    undo_count = reaper.GetProjectStateChangeCount(0) or 0
  end
  local samp = {
    play_state = play_state,
    edit_cursor = edit_cursor,
    play_cursor = play_cursor,
    is_dirty = is_dirty,
    undo_count = undo_count,
    sel_fingerprint = sel_fingerprint(reaper),
  }
  local classified = PTT.activity.classify(prev_activity, samp)
  return classified, samp
end

local function fs_copy(src, dst)
  local i = assert(io.open(src, "rb"))
  local data = i:read("*a")
  i:close()
  local o = assert(io.open(dst, "wb"))
  o:write(data)
  o:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local d = f:read("*a")
  f:close()
  return d or ""
end

local function log_path_for(ident, resource_path, pid)
  if not ident.saved or ident.guid == "" then
    return PTT.untitled.temp_path(resource_path, pid), true
  end
  local dir = ident.dir:gsub("/+$", "")
  return dir .. "/" .. ident.guid .. ".timelog.jsonl", false
end

local function emit(ctx, event_tbl)
  event_tbl.ts = event_tbl.ts or PTT.util.now_iso(ctx.time_precise)
  event_tbl.machine = ctx.machine_id
  event_tbl.project_guid = ctx.ident.guid or ""
  event_tbl.project_name = ctx.ident.name or ""
  local ok, err = ctx.writer:append(event_tbl)
  if not ok and ctx.reaper.ShowConsoleMsg then
    ctx.reaper.ShowConsoleMsg("[PTT] write warning: " .. tostring(err) .. "\n")
  end
  PTT.sync_hook.notify(event_tbl)
end

local function close_open_sessions(ctx, reason)
  local now = ctx.now()
  if ctx.wall.open then
    emit(ctx, {
      event = "session_end",
      session_id = ctx.wall.session_id,
      span_accum = ctx.wall.span_accum,
      details = { reason = reason },
    })
    ctx.wall = PTT.session_wall.new_state()
  end
  if ctx.rec.open then
    emit(ctx, {
      event = "rec_session_end",
      session_id = ctx.rec.session_id,
      rec_accum = ctx.rec.rec_accum,
      details = { reason = reason },
    })
    ctx.rec = PTT.session_rec.new_state()
  end
end

local function apply_identity_change(ctx, prev, curr, diff)
  if diff.same_folder_rename then
    ctx.ident = curr
    return
  end
  if diff.path_changed and not diff.guid_changed and prev.guid ~= "" and curr.guid ~= "" then
    close_open_sessions(ctx, "path_change")
    local old_path = ctx.writer.path
    local res = PTT.path_migrate.carry(old_path, curr.dir, curr.guid, {
      copy = fs_copy,
      rename = function(a, b) return os.rename(a, b) end,
      exists = function(p)
        local f = io.open(p, "r"); if f then f:close(); return true end; return false
      end,
    })
    ctx.writer:set_path(res.new_path)
    ctx.ident = curr
    emit(ctx, {
      event = "migrate_path",
      details = { from = old_path, to = res.new_path, bak = res.bak_path or "" },
    })
    return
  end
  if diff.became_saved then
    close_open_sessions(ctx, "became_saved")
    local dest = curr.dir:gsub("/+$", "") .. "/" .. curr.guid .. ".timelog.jsonl"
    local temp = ctx.writer.path
    PTT.untitled.migrate(temp, dest)
    ctx.writer:set_path(dest)
    ctx.ident = curr
    emit(ctx, { event = "migrate_untitled", details = { from = temp, to = dest } })
    return
  end
  if diff.guid_changed then
    close_open_sessions(ctx, "guid_change")
    ctx.ident = curr
    local path = select(1, log_path_for(curr, ctx.resource_path, ctx.pid))
    ctx.writer:set_path(path)
    return
  end
  ctx.ident = curr
end

function M.run(reaper)
  local U = PTT.util
  local already = reaper.GetExtState(EXT_NS, EXT_RUNNING) == "1"
  if already then
    reaper.SetExtState(EXT_NS, EXT_RUNNING, "0", true)
    return
  end
  reaper.SetExtState(EXT_NS, EXT_RUNNING, "1", true)

  local resource = reaper.GetResourcePath and reaper.GetResourcePath() or "/tmp"
  local pid = tostring(os.time() % 100000)
  local machine = U.machine_id({
    get_os = function() return reaper.GetOS() or "" end,
    popen_hostname = function()
      local h = io.popen("hostname")
      if not h then return nil end
      local line = h:read("*l")
      h:close()
      return line
    end,
    getenv = function(k) return os.getenv(k) end,
  })

  local ident = reaper_identity(reaper)
  local path = select(1, log_path_for(ident, resource, pid))
  local writer = PTT.writer.new({
    path = path,
    json_encode = U.json_encode,
  })

  local ctx = {
    reaper = reaper,
    writer = writer,
    ident = ident,
    machine_id = machine,
    resource_path = resource,
    pid = pid,
    wall = PTT.session_wall.new_state(),
    rec = PTT.session_rec.new_state(),
    activity_prev = {
      edit_cursor = nil,
      play_cursor = nil,
      is_dirty = false,
      undo_count = 0,
      sel_fingerprint = "",
    },
    last_heartbeat_ts = 0,
    last_tick = nil,
    time_precise = reaper.time_precise and function() return reaper.time_precise() end or nil,
    now = function() return os.time() end,
  }

  -- crash recovery
  local recovered = PTT.crash.recover(read_file(path))
  for _, action in ipairs(recovered.actions) do
    emit(ctx, action)
  end

  emit(ctx, { event = "script_start", details = { version = "2.0.0" } })

  local function tick()
    if reaper.GetExtState(EXT_NS, EXT_RUNNING) ~= "1" then
      close_open_sessions(ctx, "stop")
      -- optional report to console summary
      local sum = PTT.report.sum_log(read_file(ctx.writer.path))
      emit(ctx, {
        event = "script_stop",
        details = {
          session_span_s = sum.session_span_s,
          rec_rolling_s = sum.rec_rolling_s,
        },
      })
      reaper.ShowConsoleMsg(string.format(
        "[PTT] Stopped. Session-Span: %.1fs  Rec-Rolling: %.1fs\n",
        sum.session_span_s, sum.rec_rolling_s))
      return
    end

    local now = ctx.now()
    local precise = (ctx.time_precise and ctx.time_precise()) or now
    local dt = U.POLL_S
    if ctx.last_tick then
      dt = math.max(0, precise - ctx.last_tick)
    end
    ctx.last_tick = precise

    local curr = reaper_identity(reaper)
    local diff = PTT.identity.diff(ctx.ident, curr)
    if diff.guid_changed or diff.path_changed or diff.became_saved or diff.same_folder_rename then
      apply_identity_change(ctx, ctx.ident, curr, diff)
    else
      ctx.ident = curr
    end

    local classified = select(1, sample(reaper, ctx.activity_prev))
    ctx.activity_prev = classified.next_prev

    local wall_out = PTT.session_wall.tick(ctx.wall, {
      now = now,
      active = classified.active,
      dt = classified.active and dt or dt,
    })
    -- session_wall already applies grace rules using active flag
    ctx.wall = wall_out.state
    for _, ev in ipairs(wall_out.events) do
      local row = {
        event = ev.event,
        session_id = ev.session_id,
        span_accum = ev.span_accum,
      }
      emit(ctx, row)
    end

    local is_rec = math.floor((reaper.GetPlayStateEx(0) or 0) / 4) % 2 == 1
    local rec_out = PTT.session_rec.tick(ctx.rec, {
      now = now,
      is_recording = is_rec,
      dt = is_rec and dt or 0,
    })
    ctx.rec = rec_out.state
    for _, ev in ipairs(rec_out.events) do
      emit(ctx, {
        event = ev.event,
        session_id = ev.session_id,
        rec_accum = ev.rec_accum,
      })
    end

    if classified.active then
      if now - (ctx.last_heartbeat_ts or 0) >= U.HEARTBEAT_S then
        ctx.last_heartbeat_ts = now
        emit(ctx, {
          event = "heartbeat",
          session_id = ctx.wall.session_id or "",
          details = { reason = classified.reason },
        })
      end
    end

    reaper.defer(tick)
  end

  reaper.defer(tick)
end
