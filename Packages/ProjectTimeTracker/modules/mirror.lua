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

function M.dest_path(central_dir, guid)
  local dir = tostring(central_dir or ""):gsub("[/\\]+$", "")
  return dir .. "/" .. tostring(guid) .. ".timelog.jsonl"
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
