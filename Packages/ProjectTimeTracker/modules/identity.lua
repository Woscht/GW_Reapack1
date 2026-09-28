PTT = PTT or {}
PTT.identity = {}
local M = PTT.identity

--- Normalize project directory for stable comparisons across Save As / OS.
function M.normalize_dir(dir)
  dir = tostring(dir or "")
  dir = dir:gsub("\\", "/")
  dir = dir:gsub("/+$", "")
  -- collapse duplicate slashes (keep leading // for UNC-ish rare cases as single logic)
  dir = dir:gsub("//+", "/")
  if dir:match("^%a:/") then
    -- Windows drive letter: keep as-is after slash normalize
  end
  return dir
end

function M.snapshot(reaper_like)
  reaper_like = reaper_like or {}
  local guid = reaper_like.get_guid and reaper_like.get_guid() or ""
  guid = tostring(guid):gsub("[{}]", "")
  local dir = reaper_like.get_project_path and reaper_like.get_project_path() or ""
  dir = M.normalize_dir(dir)
  local name = reaper_like.get_project_name and reaper_like.get_project_name() or ""
  local saved = true
  if reaper_like.is_untitled then
    saved = not reaper_like.is_untitled()
  elseif name == "" or dir == "" then
    saved = false
  end
  return { guid = guid, dir = dir, name = name, saved = saved }
end

function M.diff(prev, curr)
  prev = prev or {}
  curr = curr or {}
  local pdir = M.normalize_dir(prev.dir)
  local cdir = M.normalize_dir(curr.dir)
  local guid_changed = (prev.guid or "") ~= (curr.guid or "") and (curr.guid or "") ~= ""
  local path_changed = pdir ~= cdir and cdir ~= ""
  local became_saved = (prev.saved == false) and (curr.saved == true)
  local same_folder_rename =
    pdir ~= ""
    and pdir == cdir
    and (prev.name or "") ~= (curr.name or "")
    and (curr.name or "") ~= ""
    and (prev.guid or "") == (curr.guid or "")
  -- Rename in same folder must not also count as path_changed
  if same_folder_rename then
    path_changed = false
  end
  return {
    guid_changed = guid_changed,
    path_changed = path_changed,
    became_saved = became_saved,
    same_folder_rename = same_folder_rename,
  }
end
