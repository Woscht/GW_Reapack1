PTT = PTT or {}
PTT.bootstrap = {}
local M = PTT.bootstrap

function M.mark_occupancy(ctx)
  ctx.occupancy_since_iso = PTT.util.now_iso(ctx.time_precise)
end

function M.after_session_flush(ctx)
  if PTT.notes_prompt and PTT.notes_prompt.begin then
    PTT.notes_prompt.begin(ctx)
  end
end

local EXT_NS = "ProjectTimeTracker"
local EXT_RUNNING = "running"
local EXT_CONFIG_PATH = "ptt_config_path"

local function load_ptt_config(reaper)
  local paths = {}
  local ext_path = reaper.GetExtState(EXT_NS, EXT_CONFIG_PATH)
  if ext_path and ext_path ~= "" then
    paths[#paths + 1] = ext_path
  end
  for _, p in ipairs(PTT.config.CANDIDATE_PATHS or {}) do
    paths[#paths + 1] = p
  end
  local cfg, src = PTT.config.load_from_paths(paths)
  local os_name = reaper.GetOS and reaper.GetOS() or ""
  cfg.central_timelogs_dir = PTT.config.adapt_central_dir(cfg.central_timelogs_dir, os_name)
  if cfg.mirror_enabled and cfg.central_timelogs_dir == "" then
    if src then
      reaper.ShowConsoleMsg("[PTT] ptt_config.json loaded but central_timelogs_dir is empty; mirror disabled\n")
    else
      reaper.ShowConsoleMsg(
        "[PTT] no ptt_config.json found (check /Volumes/PRODUKTION or UNC); mirror disabled\n")
    end
  end
  if cfg.notes_auto_open ~= false then
    local base = cfg.notes_ui_base_url or ""
    if base == "" then
      reaper.ShowConsoleMsg(
        "[PTT] notes_auto_open is on but notes_ui_base_url is empty — Arbeitskommentar-Dialog nicht möglich\n")
    end
  end
  return cfg
end

local function script_dir_from_debug()
  -- filled by entry via PTT._script_root
  return PTT._script_root or ""
end

local function reaper_identity(reaper, prefer_guid)
  return PTT.identity.snapshot({
    get_guid = function()
      -- Prefer our stable ExtState id. Stock GetSetProjectInfo_String("PROJECT_GUID")
      -- is empty on some builds and can change across Save As on others — never let
      -- it override an already assigned tracker id.
      local ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
      if ret == 1 and stored and stored ~= "" then return stored end
      -- Also accept uppercase key as written into .rpp EXTSTATE blocks.
      ret, stored = reaper.GetProjExtState(0, "ProjectTimeTracker", "PROJECT_GUID")
      if ret == 1 and stored and stored ~= "" then
        reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", stored)
        return stored
      end
      local ok, guid = reaper.GetSetProjectInfo_String(0, "PROJECT_GUID", "", false)
      if ok and guid and guid ~= "" then
        reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", guid)
        return guid
      end
      -- Save As can briefly clear ExtState while the same project object remains.
      if prefer_guid and prefer_guid ~= "" then
        reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", prefer_guid)
        return prefer_guid
      end
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
  return PTT.path_migrate.local_log_path(ident.dir, ident.guid), false
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

local function emit_progress(ctx, event_name, reason)
  local fields = PTT.util.progress_fields(ctx.wall, ctx.rec)
  if fields.span_accum == nil and fields.rec_accum == nil then
    return false
  end
  local row = {
    event = event_name,
    session_id = fields.session_id or (ctx.wall.session_id or ""),
    details = { reason = reason },
  }
  if fields.span_accum ~= nil then row.span_accum = fields.span_accum end
  if fields.rec_accum ~= nil then row.rec_accum = fields.rec_accum end
  emit(ctx, row)
  return true
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
    -- Ensure guid stays persisted under the new filename after Save As.
    if curr.guid and curr.guid ~= "" and ctx.reaper.SetProjExtState then
      ctx.reaper.SetProjExtState(0, "ProjectTimeTracker", "project_guid", curr.guid)
    end
    ctx.ident = curr
    return
  end
  if diff.path_changed and not diff.guid_changed and prev.guid ~= "" and curr.guid ~= "" then
    close_open_sessions(ctx, "path_change")
    local old_path = ctx.writer.path
    local ok_mig, res = pcall(function()
      return PTT.path_migrate.carry(old_path, curr.dir, curr.guid, {
        copy = fs_copy,
        rename = function(a, b) return os.rename(a, b) end,
        exists = function(p)
          local f = io.open(p, "r"); if f then f:close(); return true end; return false
        end,
      })
    end)
    if not ok_mig then
      if ctx.reaper.ShowConsoleMsg then
        ctx.reaper.ShowConsoleMsg("[PTT] path migrate failed: " .. tostring(res) .. "\n")
      end
      -- Fall back: keep writing to a fresh path in the new dir without deleting old.
      local fallback = PTT.path_migrate.local_log_path(curr.dir, curr.guid)
      ctx.writer:set_path(fallback)
      ctx.ident = curr
      return
    end
    ctx.writer:set_path(res.new_path)
    ctx.ident = curr
    if not res.same_path then
      emit(ctx, {
        event = "migrate_path",
        details = { from = old_path, to = res.new_path, bak = res.bak_path or "" },
      })
    end
    return
  end
  if diff.became_saved then
    close_open_sessions(ctx, "became_saved")
    local dest = PTT.path_migrate.local_log_path(curr.dir, curr.guid)
    local temp = ctx.writer.path
    local parent = dest:match("^(.+)[/\\][^/\\]+$")
    if parent and PTT.mirror and PTT.mirror.io_fs then
      PTT.mirror.io_fs().mkdir_p(parent)
    elseif parent then
      os.execute('mkdir -p "' .. parent:gsub('"', '\\"') .. '"')
    end
    PTT.untitled.migrate(temp, dest)
    ctx.writer:set_path(dest)
    ctx.ident = curr
    emit(ctx, { event = "migrate_untitled", details = { from = temp, to = dest } })
    return
  end
  if diff.guid_changed then
    -- If the project object is unchanged, treat reminted guid as a bug and keep old.
    if ctx.proj_ptr and curr.guid ~= prev.guid and prev.guid ~= "" then
      -- Still allow real project switches (handled when proj_ptr changes in tick).
    end
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

  local ident = reaper_identity(reaper, nil)
  local path = select(1, log_path_for(ident, resource, pid))
  local writer = PTT.writer.new({
    path = path,
    json_encode = U.json_encode,
  })

  local ctx = {
    reaper = reaper,
    writer = writer,
    ident = ident,
    cfg = load_ptt_config(reaper),
    last_mirror_ts = 0,
    last_mirror_warn_ts = 0,
    mirror_warned = false,
    machine_id = machine,
    resource_path = resource,
    pid = pid,
    proj_ptr = reaper.EnumProjects(-1),
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

  M.mark_occupancy(ctx)

  -- Pull central history before crash recovery when local is missing/short.
  PTT.mirror.maybe_hydrate(ctx)

  -- crash recovery
  local recovered = PTT.crash.recover(read_file(ctx.writer.path))
  for _, action in ipairs(recovered.actions) do
    emit(ctx, action)
  end

  emit(ctx, { event = "script_start", details = { version = PTT.VERSION or "2.1.6" } })
  ctx.was_dirty = false
  ctx.was_recording = false
  ctx.last_save_mirror_ts = 0
  PTT.mirror.maybe_mirror(ctx, { force = true })

  local function tick()
    if reaper.GetExtState(EXT_NS, EXT_RUNNING) ~= "1" then
      if not ctx.notes_stopping then
        close_open_sessions(ctx, "stop")
        local sum = PTT.report.sum_log(read_file(ctx.writer.path))
        emit(ctx, {
          event = "script_stop",
          details = {
            session_span_s = sum.session_span_s,
            rec_rolling_s = sum.rec_rolling_s,
          },
        })
        PTT.mirror.maybe_mirror(ctx, { force = true })
        M.after_session_flush(ctx)
        ctx.notes_stopping = true
        ctx._stop_sum = sum
      end
      if ctx.notes_prompt and PTT.notes_prompt and PTT.notes_prompt.tick then
        local r = PTT.notes_prompt.tick(ctx)
        if r == "open" then
          reaper.defer(tick)
          return
        end
      end
      local sum = ctx._stop_sum or { session_span_s = 0, rec_rolling_s = 0 }
      reaper.ShowConsoleMsg(string.format(
        "[PTT] Stopped. Session-Span: %.1fs  Rec-Rolling: %.1fs\n",
        sum.session_span_s, sum.rec_rolling_s))
      return
    end

    if ctx.notes_prompt and PTT.notes_prompt and PTT.notes_prompt.tick then
      PTT.notes_prompt.tick(ctx)
    end

    local _, fn = reaper.EnumProjects(-1, "")
    local untitled = (not fn or fn == "")
    -- Best-effort project close: flush old log, but do NOT reset ctx.ident —
    -- leave identity transition to apply_identity_change so writer.path stays in sync.
    if untitled and ctx.ident and ctx.ident.saved then
      close_open_sessions(ctx, "project_close")
      PTT.mirror.maybe_mirror(ctx, { force = true })
      M.after_session_flush(ctx)
    end

    local now = ctx.now()
    local precise = (ctx.time_precise and ctx.time_precise()) or now
    local dt = U.POLL_S
    if ctx.last_tick then
      dt = math.max(0, precise - ctx.last_tick)
    end
    ctx.last_tick = precise

    local proj = reaper.EnumProjects(-1)
    local same_proj = (ctx.proj_ptr ~= nil and proj == ctx.proj_ptr)
    local prefer = same_proj and ctx.ident.guid or nil
    -- If the on-disk project directory changed, treat as a real project switch even
    -- when REAPER keeps the same project pointer (seen on Linux headless opens).
    if prefer and prefer ~= "" then
      local _, fn_now = reaper.EnumProjects(-1, "")
      local new_dir = ""
      if fn_now and fn_now ~= "" then
        new_dir = fn_now:match("^(.*)[/\\][^/\\]+$") or ""
        new_dir = PTT.identity.normalize_dir(new_dir)
      end
      local old_dir = PTT.identity.normalize_dir(ctx.ident.dir or "")
      if old_dir ~= "" and new_dir ~= "" and old_dir ~= new_dir then
        prefer = nil
      end
    end
    local curr = reaper_identity(reaper, prefer)
    if not same_proj then
      ctx.proj_ptr = proj
    end
    local diff = PTT.identity.diff(ctx.ident, curr)
    -- Opening a different project: allow guid change without prefer contamination
    if not same_proj and diff.guid_changed then
      -- ok
    elseif same_proj and diff.guid_changed and prefer and prefer ~= "" then
      -- Should not happen after prefer_guid; force keep
      curr.guid = prefer
      diff = PTT.identity.diff(ctx.ident, curr)
    end
    if diff.guid_changed or diff.path_changed or diff.became_saved or diff.same_folder_rename then
      -- Close open sessions first so the pre-switch mirror includes session_end.
      if diff.guid_changed or diff.path_changed or diff.became_saved then
        close_open_sessions(ctx, "identity_pre_mirror")
      end
      PTT.mirror.maybe_mirror(ctx, { force = true })
      -- Prompt documentation for the project being left (before identity swap).
      M.after_session_flush(ctx)
      local ok_apply, err_apply = pcall(apply_identity_change, ctx, ctx.ident, curr, diff)
      if not ok_apply then
        reaper.ShowConsoleMsg("[PTT] identity change error: " .. tostring(err_apply) .. "\n")
        ctx.ident = curr
      end
      if diff.guid_changed or diff.path_changed or diff.became_saved then
        M.mark_occupancy(ctx)
      end
      -- New path/GUID: pull central history if local is empty/short, then push.
      PTT.mirror.maybe_hydrate(ctx)
      PTT.mirror.maybe_mirror(ctx, { force = true })
    else
      ctx.ident = curr
    end

    local classified = select(1, sample(reaper, ctx.activity_prev))
    ctx.activity_prev = classified.next_prev

    local curr_dirty = classified.next_prev and classified.next_prev.is_dirty
    if curr_dirty == nil then
      curr_dirty = (reaper.IsProjectDirty(0) or 0) ~= 0
    end
    local debounce = (ctx.cfg and ctx.cfg.mirror_save_debounce_s) or 30
    local force_save_mirror = PTT.mirror.should_force_on_save(
      ctx.was_dirty, curr_dirty, now, ctx.last_save_mirror_ts, debounce)
    ctx.was_dirty = curr_dirty

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

    -- Persist progress when a take stops (session stays open for punch-ins).
    if ctx.was_recording and not is_rec and ctx.rec.open then
      emit_progress(ctx, "checkpoint", "rec_stop")
    end
    ctx.was_recording = is_rec

    -- Save: checkpoint then force-mirror so central share has latest accum.
    if force_save_mirror then
      emit_progress(ctx, "checkpoint", "save")
      PTT.mirror.maybe_mirror(ctx, { force = true })
      ctx.last_save_mirror_ts = now
    end

    if classified.active then
      if now - (ctx.last_heartbeat_ts or 0) >= U.HEARTBEAT_S then
        ctx.last_heartbeat_ts = now
        local hb = {
          event = "heartbeat",
          session_id = ctx.wall.session_id or "",
          details = { reason = classified.reason },
        }
        local fields = U.progress_fields(ctx.wall, ctx.rec)
        if fields.span_accum ~= nil then hb.span_accum = fields.span_accum end
        if fields.rec_accum ~= nil then hb.rec_accum = fields.rec_accum end
        if fields.session_id then hb.session_id = fields.session_id end
        emit(ctx, hb)
      end
    end

    PTT.mirror.maybe_mirror(ctx)

    reaper.defer(tick)
  end

  reaper.defer(tick)
end
