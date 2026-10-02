PTT = PTT or {}
PTT.mirror = PTT.mirror or {}
local M = PTT.mirror

function M.dest_path(central_dir, guid)
  local dir = tostring(central_dir or ""):gsub("[/\\]+$", "")
  return dir .. "/" .. tostring(guid) .. ".timelog.jsonl"
end

local function parent_dir(path)
  return path:match("^(.+)/[^/]+$")
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
