PTT = PTT or {}
PTT.identity = {}
local M = PTT.identity

function M.snapshot(reaper_like)
  reaper_like = reaper_like or {}
  local guid = reaper_like.get_guid and reaper_like.get_guid() or ""
  guid = tostring(guid):gsub("[{}]", "")
  local dir = reaper_like.get_project_path and reaper_like.get_project_path() or ""
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
  local guid_changed = (prev.guid or "") ~= (curr.guid or "") and (curr.guid or "") ~= ""
  local path_changed = (prev.dir or "") ~= (curr.dir or "") and (curr.dir or "") ~= ""
  local became_saved = (prev.saved == false) and (curr.saved == true)
  local same_folder_rename =
    (prev.dir or "") == (curr.dir or "")
    and (prev.name or "") ~= (curr.name or "")
    and (prev.guid or "") == (curr.guid or "")
  return {
    guid_changed = guid_changed,
    path_changed = path_changed,
    became_saved = became_saved,
    same_folder_rename = same_folder_rename,
  }
end
