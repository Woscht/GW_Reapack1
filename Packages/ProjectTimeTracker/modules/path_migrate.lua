PTT = PTT or {}
PTT.path_migrate = {}
local M = PTT.path_migrate

function M.carry(old_path, new_dir, guid, fs)
  fs = fs or {}
  local copy = fs.copy
  local rename = fs.rename
  local exists = fs.exists or function(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
  end

  local fname = guid .. ".timelog.jsonl"
  local new_path = new_dir:gsub("/+$", "") .. "/" .. fname
  local bak_path = old_path .. ".bak"

  if not exists(old_path) then
    return { new_path = new_path, bak_path = nil, skipped = true }
  end

  assert(copy, "fs.copy required")
  assert(rename, "fs.rename required")
  copy(old_path, new_path)
  rename(old_path, bak_path)
  return { new_path = new_path, bak_path = bak_path, skipped = false }
end
