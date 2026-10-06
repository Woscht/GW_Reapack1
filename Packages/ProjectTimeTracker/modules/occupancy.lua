PTT = PTT or {}
PTT.occupancy = PTT.occupancy or {}
local M = PTT.occupancy

--- Keep only when at least one save this occupancy and leave is not dirty.
function M.should_discard(save_seen, dirty_at_leave)
  if dirty_at_leave then
    return true
  end
  if not save_seen then
    return true
  end
  return false
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
