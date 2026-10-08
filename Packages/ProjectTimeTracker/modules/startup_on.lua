PTT = PTT or {}
PTT.startup_on = PTT.startup_on or {}
local M = PTT.startup_on

M.BEGIN = "-- >>> PTT always-on BEGIN"
M.END = "-- <<< PTT always-on END"

function M.startup_file(resource_path)
  resource_path = tostring(resource_path or ""):gsub("[/\\]+$", "")
  if resource_path == "" then
    return nil
  end
  local sep = package.config:sub(1, 1)
  return resource_path .. sep .. "Scripts" .. sep .. "__startup.lua"
end

function M.block_for_path(ptt_path)
  ptt_path = tostring(ptt_path or "")
  if ptt_path == "" then
    return nil
  end
  return table.concat({
    M.BEGIN,
    "do",
    "  local p = " .. string.format("%q", ptt_path),
    "  local f = io.open(p, \"r\")",
    "  if f then f:close(); dofile(p) end",
    "end",
    M.END,
  }, "\n")
end

function M.is_enabled(content)
  content = tostring(content or "")
  return content:find(M.BEGIN, 1, true) ~= nil and content:find(M.END, 1, true) ~= nil
end

--- Remove marked PTT block. Returns new content, removed (bool).
function M.strip_block(content)
  content = tostring(content or "")
  local s = content:find(M.BEGIN, 1, true)
  local e = content:find(M.END, 1, true)
  if not s or not e or e < s then
    return content, false
  end
  local after = e + #M.END
  -- Drop one following newline if present
  if content:sub(after, after + 1) == "\r\n" then
    after = after + 2
  elseif content:sub(after, after) == "\n" then
    after = after + 1
  end
  -- Drop one preceding newline so we don't leave double blanks awkwardly
  local before = s
  if before > 1 and content:sub(before - 1, before - 1) == "\n" then
    before = before - 1
    if before > 1 and content:sub(before - 1, before - 1) == "\r" then
      before = before - 1
    end
  end
  local out = content:sub(1, before - 1) .. content:sub(after)
  return out, true
end

--- Ensure exactly one block for ptt_path. Returns new content, changed (bool).
function M.ensure_block(content, ptt_path)
  local block = M.block_for_path(ptt_path)
  if not block then
    return content, false
  end
  local stripped = M.strip_block(content)
  if stripped ~= "" and not stripped:match("\n$") then
    stripped = stripped .. "\n"
  end
  local out = stripped .. block .. "\n"
  return out, out ~= tostring(content or "")
end

function M.read_file(path, io_open)
  io_open = io_open or io.open
  local f = io_open(path, "rb")
  if not f then
    return ""
  end
  local data = f:read("*a") or ""
  f:close()
  return data
end

function M.write_file(path, content, io_open)
  io_open = io_open or io.open
  local f = io_open(path, "wb")
  if not f then
    return false
  end
  f:write(content or "")
  f:close()
  return true
end

--- Enable always-on. opts: resource_path, ptt_path, io_open
--- Returns ok, reason ("enabled"|"already"|"no_resource"|"no_ptt"|"write_failed")
function M.enable(opts)
  opts = opts or {}
  local startup = M.startup_file(opts.resource_path)
  if not startup then
    return false, "no_resource"
  end
  if not opts.ptt_path or opts.ptt_path == "" then
    return false, "no_ptt"
  end
  local io_open = opts.io_open or io.open
  local cur = M.read_file(startup, io_open)
  local next_body = select(1, M.ensure_block(cur, opts.ptt_path))
  if not M.write_file(startup, next_body, io_open) then
    return false, "write_failed"
  end
  if M.is_enabled(cur) and cur == next_body then
    return true, "already"
  end
  return true, "enabled"
end

--- Disable always-on. Returns ok, reason ("disabled"|"absent"|"no_resource"|"write_failed")
function M.disable(opts)
  opts = opts or {}
  local startup = M.startup_file(opts.resource_path)
  if not startup then
    return false, "no_resource"
  end
  local io_open = opts.io_open or io.open
  local cur = M.read_file(startup, io_open)
  if not M.is_enabled(cur) then
    return true, "absent"
  end
  local next_body = select(1, M.strip_block(cur))
  if not M.write_file(startup, next_body, io_open) then
    return false, "write_failed"
  end
  return true, "disabled"
end
