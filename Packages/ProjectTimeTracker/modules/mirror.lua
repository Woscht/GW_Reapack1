PTT = PTT or {}
PTT.mirror = PTT.mirror or {}
local M = PTT.mirror

M.WARN_INTERVAL_S = 300

function M.should_run(last_ts, now, interval_s)
  interval_s = interval_s or 0
  if interval_s <= 0 then
    return false
  end
  return (now - (last_ts or 0)) >= interval_s
end

function M.should_force_on_save(prev_dirty, curr_dirty, now, last_save_mirror_ts, debounce_s)
  if not prev_dirty or curr_dirty then
    return false
  end
  debounce_s = debounce_s or 30
  if debounce_s < 0 then debounce_s = 0 end
  return (now - (last_save_mirror_ts or 0)) >= debounce_s
end

--- Count non-empty JSONL lines (billing/history completeness heuristic).
function M.line_count(text)
  if text == nil or text == "" then
    return 0
  end
  local n = 0
  for _ in tostring(text):gmatch("[^\r\n]+") do
    n = n + 1
  end
  return n
end

--- Push local→central only when local is at least as long (never shrink central).
function M.should_overwrite_central(local_text, central_text)
  local cc = M.line_count(central_text)
  if cc == 0 then
    return true
  end
  local lc = M.line_count(local_text)
  if lc == 0 then
    return false
  end
  return lc >= cc
end

function M.io_fs()
  return {
    read_all = function(path)
      local f = io.open(path, "rb")
      if not f then
        return nil
      end
      local data = f:read("*a")
      f:close()
      return data
    end,
    write_all = function(path, data)
      local f, err = io.open(path, "wb")
      if not f then
        return false, err or "write failed"
      end
      f:write(data)
      f:close()
      return true
    end,
    rename = function(a, b)
      local ok, err = os.rename(a, b)
      if ok then
        return true
      end
      return false, err or "rename failed"
    end,
    remove = function(path)
      os.remove(path)
      return true
    end,
    mkdir_p = function(dir)
      if dir == "" or dir == nil then
        return true
      end
      dir = tostring(dir)
      local function writable()
        local probe = dir:gsub("[/\\]+$", "") .. "/.ptt_mkdir_probe"
        local f = io.open(probe, "wb")
        if not f then
          return false
        end
        f:close()
        os.remove(probe)
        return true
      end
      -- Already usable (common: admin pre-created the share folder).
      if writable() then
        return true
      end
      -- Prefer REAPER's cross-platform API (Windows DAWs cannot use mkdir -p).
      -- Note: on Linux, RecursiveCreateDirectory may return 0 when the path
      -- already exists — treat writeability as the success criterion.
      if type(reaper) == "table" and type(reaper.RecursiveCreateDirectory) == "function" then
        reaper.RecursiveCreateDirectory(dir, 0)
        if writable() then
          return true
        end
      end
      local shell_ok = os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
      if (shell_ok == true or shell_ok == 0) and writable() then
        return true
      end
      return false, "mkdir failed"
    end,
  }
end

local function parent_dir(path)
  return path:match("^(.+)[/\\][^/\\]+$")
end

local function replace_file(tmp, dest, fs)
  local ok, err = fs.rename(tmp, dest)
  if ok then
    return true
  end
  fs.remove(dest)
  ok, err = fs.rename(tmp, dest)
  if ok then
    return true
  end
  return false, err or "rename failed"
end

function M.maybe_mirror(ctx, opts)
  opts = opts or {}
  local cfg = ctx.cfg
  if not cfg or not cfg.mirror_enabled then
    return
  end
  local central = cfg.central_timelogs_dir
  if type(central) ~= "string" or central == "" then
    return
  end
  local now = opts.now or (ctx.now and ctx.now()) or os.time()
  local interval = cfg.mirror_interval_s or 300
  if not opts.force and not M.should_run(ctx.last_mirror_ts, now, interval) then
    return
  end
  local guid = ctx.ident and ctx.ident.guid or ""
  if guid == "" then
    return
  end
  local src = ctx.writer and ctx.writer.path
  if not src or src == "" then
    return
  end
  local fs = opts.fs or M.io_fs()
  local dest = M.dest_path(central, guid)
  local local_data = fs.read_all(src)
  local central_data = fs.read_all(dest)
  if not M.should_overwrite_central(local_data, central_data) then
    local last_warn = ctx.last_mirror_warn_ts or 0
    if now - last_warn >= M.WARN_INTERVAL_S then
      ctx.last_mirror_warn_ts = now
      ctx.mirror_warned = true
      local reaper = ctx.reaper
      if reaper and reaper.ShowConsoleMsg then
        reaper.ShowConsoleMsg(
          "[PTT] mirror skipped: central log longer than local (hydrate or copy timetracker/)\n")
      end
    end
    return
  end
  local ok, err = M.atomic_copy(src, dest, fs)
  if ok and err ~= "skip" then
    ctx.last_mirror_ts = now
    return
  end
  if ok then
    return
  end
  local last_warn = ctx.last_mirror_warn_ts or 0
  if now - last_warn < M.WARN_INTERVAL_S then
    return
  end
  ctx.last_mirror_warn_ts = now
  ctx.mirror_warned = true
  local reaper = ctx.reaper
  if reaper and reaper.ShowConsoleMsg then
    reaper.ShowConsoleMsg("[PTT] mirror warning: " .. tostring(err) .. "\n")
  end
end

--- Copy central→local when local is missing or shorter (same GUID).
function M.hydrate_if_needed(local_path, central_path, fs)
  fs = fs or M.io_fs()
  if not local_path or local_path == "" or not central_path or central_path == "" then
    return false, "bad_path"
  end
  local central_data = fs.read_all(central_path)
  if central_data == nil or central_data == "" then
    return false, "no_central"
  end
  local local_data = fs.read_all(local_path)
  local lc = M.line_count(local_data)
  local cc = M.line_count(central_data)
  if lc >= cc then
    return false, "local_ok"
  end
  local dir = parent_dir(local_path)
  if dir and fs.mkdir_p then
    local mk_ok, mk_err = fs.mkdir_p(dir)
    if mk_ok == false then
      return false, mk_err or "mkdir failed"
    end
  end
  local tmp = local_path .. ".hydrate.tmp"
  local w_ok, w_err = fs.write_all(tmp, central_data)
  if w_ok == false then
    return false, w_err or "write failed"
  end
  local r_ok, r_err = replace_file(tmp, local_path, fs)
  if not r_ok then
    return false, r_err or "rename failed"
  end
  return true, "hydrated"
end

function M.maybe_hydrate(ctx, opts)
  opts = opts or {}
  local cfg = ctx and ctx.cfg
  if not cfg or not cfg.mirror_enabled then
    return false, "disabled"
  end
  local central = cfg.central_timelogs_dir
  if type(central) ~= "string" or central == "" then
    return false, "no_central_dir"
  end
  local guid = ctx.ident and ctx.ident.guid or ""
  if guid == "" then
    return false, "no_guid"
  end
  local local_path = ctx.writer and ctx.writer.path
  if not local_path or local_path == "" then
    return false, "no_local"
  end
  local fs = opts.fs or M.io_fs()
  local central_path = M.dest_path(central, guid)
  local ok, reason = M.hydrate_if_needed(local_path, central_path, fs)
  if ok and ctx.reaper and ctx.reaper.ShowConsoleMsg then
    ctx.reaper.ShowConsoleMsg("[PTT] hydrated local log from central (" .. tostring(guid) .. ")\n")
  end
  return ok, reason
end

function M.dest_path(central_dir, guid)
  local dir = tostring(central_dir or ""):gsub("[/\\]+$", "")
  return dir .. "/" .. tostring(guid) .. ".timelog.jsonl"
end

function M.atomic_copy(src, dest, fs)
  local function run()
    local data = fs.read_all(src)
    if data == nil or data == "" then
      return true, "skip"
    end
    local dir = parent_dir(dest)
    if dir then
      local mk_ok, mk_err = fs.mkdir_p(dir)
      if mk_ok == false then
        return false, mk_err or "mkdir failed"
      end
    end
    local tmp = dest .. ".tmp"
    local w_ok, w_err = fs.write_all(tmp, data)
    if w_ok == false then
      return false, w_err or "write failed"
    end
    local r_ok, r_err = replace_file(tmp, dest, fs)
    if not r_ok then
      return false, r_err
    end
    return true
  end
  local status, ok, err = pcall(run)
  if not status then
    return false, tostring(ok)
  end
  return ok, err
end
