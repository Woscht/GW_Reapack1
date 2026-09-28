PTT = PTT or {}
PTT.untitled = {}
local M = PTT.untitled

function M.temp_path(resource_path, pid)
  resource_path = (resource_path or "/tmp"):gsub("/+$", "")
  pid = pid or "0"
  return resource_path .. "/PTT_untitled_" .. tostring(pid) .. ".timelog.jsonl"
end

function M.migrate(temp_path, dest_path, fs)
  fs = fs or {}
  local exists = fs.exists or function(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
  end
  local read_all = fs.read_all or function(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
  end
  local append = fs.append or function(p, data)
    local f = assert(io.open(p, "a+"))
    f:write(data)
    f:close()
  end
  local remove = fs.remove or os.remove

  if not exists(temp_path) then
    return false, "no temp"
  end
  local data = read_all(temp_path) or ""
  if #data > 0 then
    append(dest_path, data)
  end
  remove(temp_path)
  return true
end
