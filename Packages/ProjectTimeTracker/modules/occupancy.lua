PTT = PTT or {}
PTT.occupancy = PTT.occupancy or {}
local M = PTT.occupancy

M.SAVE_ON_CLOSE_WINDOW_S = 30

--- Keep only when at least one save this occupancy and leave is not dirty.
--- `saved_on_close`: .RPP mtime is fresh (Save Yes in close dialog) — we never
--- observe dirty→clean while the project is still open in that case.
function M.should_discard(save_seen, dirty_at_leave, saved_on_close)
  if saved_on_close then
    return false
  end
  if dirty_at_leave then
    return true
  end
  if not save_seen then
    return true
  end
  return false
end

function M.project_file_path(ident)
  ident = ident or {}
  local dir = tostring(ident.dir or ""):gsub("[/\\]+$", "")
  local name = tostring(ident.name or "")
  if dir == "" or name == "" then
    return nil
  end
  local sep = package.config:sub(1, 1)
  return dir .. sep .. name
end

--- Unix mtime of path, or nil. `popen` injectable for tests.
function M.file_mtime(path, popen)
  popen = popen or io.popen
  if not path or path == "" then
    return nil
  end
  local q = tostring(path):gsub('"', '\\"')
  -- macOS: stat -f %m ; Linux: stat -c %Y
  local h = popen('stat -f %m "' .. q .. '" 2>/dev/null || stat -c %Y "' .. q .. '" 2>/dev/null')
  if not h then
    return nil
  end
  local line = h:read("*l")
  h:close()
  local n = tonumber(line)
  return n
end

--- True when project file was written within the last window_s seconds (Save-on-close).
function M.detect_saved_on_close(ident, now_unix, opts)
  opts = opts or {}
  local window = opts.window_s or M.SAVE_ON_CLOSE_WINDOW_S
  local path = opts.path or M.project_file_path(ident)
  if not path then
    return false
  end
  local mtime = opts.mtime
  if mtime == nil then
    mtime = M.file_mtime(path, opts.popen)
  end
  if not mtime then
    return false
  end
  now_unix = now_unix or os.time()
  local age = now_unix - mtime
  return age >= 0 and age <= window
end

local function line_ts(line)
  return tostring(line or ""):match('"ts"%s*:%s*"([^"]+)"')
end

--- Drop JSONL events with ts >= since_iso. Rewrites path. Returns kept, removed counts.
function M.strip_events_since(path, since_iso, io_open)
  io_open = io_open or io.open
  if not path or path == "" or not since_iso or since_iso == "" then
    return 0, 0
  end
  local f = io_open(path, "rb")
  if not f then
    return 0, 0
  end
  local data = f:read("*a") or ""
  f:close()
  local keep = {}
  local kept, removed = 0, 0
  for line in tostring(data):gmatch("[^\r\n]+") do
    local ts = line_ts(line)
    if ts and ts >= since_iso then
      removed = removed + 1
    else
      keep[#keep + 1] = line
      kept = kept + 1
    end
  end
  local out = table.concat(keep, "\n")
  if out ~= "" then
    out = out .. "\n"
  end
  local w = io_open(path, "wb")
  if not w then
    return kept, removed
  end
  w:write(out)
  w:close()
  return kept, removed
end

function M.reset_flags(ctx)
  if not ctx then
    return
  end
  ctx.occupancy_save_seen = false
  ctx.occupancy_dirty_seen = false
end

function M.note_dirty_transition(ctx, prev_dirty, curr_dirty)
  if not ctx then
    return
  end
  if curr_dirty then
    ctx.occupancy_dirty_seen = true
  end
  if prev_dirty and not curr_dirty then
    ctx.occupancy_save_seen = true
  end
end
