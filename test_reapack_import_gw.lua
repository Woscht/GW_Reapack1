-- test_reapack_import_gw.lua
-- Headless verification: import GW_Reapack1 and install ProjectTimeTracker.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/reapack_import_gw_status.txt"
local INDEX_URL = "https://raw.githubusercontent.com/Woscht/GW_Reapack1/main/index.xml"
local REPO_NAME_EXPECTED = "GW_Reapack1"
local LOCAL_INDEX = "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/index.xml"

local function write_status(line)
  local f = io.open(STATUS, "w")
  if f then
    f:write(line .. "\n")
    f:close()
  end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function fail(msg)
  write_status("ERROR: " .. msg)
end

local function ok(msg)
  write_status("OK: " .. msg)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function fetch_url(url)
  local tmp = "/tmp/reapack_index_fetch.xml"
  os.remove(tmp)
  -- Wrapper avoids ExecProcess quote-splitting bugs with URLs.
  local cmd = "/bin/bash /tmp/fetch_gw_index.sh " .. tmp
  if reaper.ExecProcess then
    reaper.ExecProcess(cmd, 35000)
  else
    os.execute(cmd)
  end
  return read_file(tmp)
end

local function validate_index(xml, label)
  if not xml or xml == "" then
    return nil, label .. ": empty index"
  end
  local name = xml:match('<index[^>]*name%s*=%s*"([^"]+)"')
  if not name or name == "" then
    return nil, label .. ": missing required name attribute"
  end
  if name ~= REPO_NAME_EXPECTED then
    return nil, string.format("%s: unexpected name %q", label, name)
  end
  if not xml:find('file="ProjectTimeTracker_Stop.lua"', 1, true) then
    return nil, label .. ': missing file="ProjectTimeTracker_Stop.lua"'
  end
  if not xml:find('file="ProjectTimeTracker.lua"', 1, true) then
    return nil, label .. ': missing file="ProjectTimeTracker.lua"'
  end
  if not xml:find('main="main"', 1, true) then
    return nil, label .. ': missing main="main"'
  end
  if xml:find('type="auxiliary"', 1, true) then
    return nil, label .. ": invalid type=auxiliary still present"
  end
  return name, nil
end

if not reaper.APIExists("ReaPack_AddSetRepository") then
  fail("ReaPack API missing (plugin not loaded)")
  return
end

-- 1) Validate local index (source of truth we published)
local local_xml = read_file(LOCAL_INDEX)
local name, err = validate_index(local_xml, "local index.xml")
if err then fail(err) return end

-- 2) Validate published GitHub index (what ReaPack Import fetches)
local remote_xml = fetch_url(INDEX_URL)
name, err = validate_index(remote_xml, "GitHub index.xml")
if err then
  -- Retry once with cache-buster
  remote_xml = fetch_url(INDEX_URL .. "?ts=" .. tostring(os.time()))
  name, err = validate_index(remote_xml, "GitHub index.xml (retry)")
  if err then fail(err) return end
end

-- 3) Register repository like Import (name taken from index)
-- autoInstall: 0=manual, 1=when synchronizing, 2=obey user setting
reaper.ReaPack_AddSetRepository(name, INDEX_URL, true, 1)
local info_ok = reaper.ReaPack_GetRepositoryInfo(name)
if not info_ok then
  fail("Repository not registered after AddSetRepository: " .. name)
  return
end

if reaper.APIExists("ReaPack_ProcessQueue") then
  reaper.ReaPack_ProcessQueue(true)
end

local sync_cmd = reaper.NamedCommandLookup("_REAPACK_SYNC")
if sync_cmd and sync_cmd ~= 0 then
  reaper.Main_OnCommand(sync_cmd, 0)
end

local resource = reaper.GetResourcePath()
local attempts = 0
local max_attempts = 60 -- ~30s

local function file_exists(path)
  local fh = io.open(path, "r")
  if fh then fh:close() return true end
  return false
end

local function find_scripts()
  local p = io.popen('find "' .. resource .. '/Scripts" -name "ProjectTimeTracker*.lua" 2>/dev/null')
  local found = p and p:read("*a") or ""
  if p then p:close() end
  return found
end

local function check_done()
  attempts = attempts + 1
  local found = find_scripts()
  local has_main = found:find("ProjectTimeTracker.lua", 1, true)
    and not found:find("ProjectTimeTracker.lua\n", 1, true) -- always true-ish; keep simple
  local has_stop = found:find("ProjectTimeTracker_Stop.lua", 1, true)
  -- Require both filenames present
  if found:find("ProjectTimeTracker.lua", 1, true)
      and found:find("ProjectTimeTracker_Stop.lua", 1, true) then
    -- Verify both are registered as actions if possible
    local detail = found:gsub("\n", " | ")
    ok(string.format(
      "Imported %s from %s; installed scripts: %s",
      name, INDEX_URL, detail))
    return
  end
  if attempts >= max_attempts then
    fail(string.format(
      "Repo %s registered, but package files not installed after sync. find=%s",
      name, (found ~= "" and found or "(none)")))
    return
  end
  -- Periodically nudge queue/sync
  if attempts % 10 == 0 then
    if reaper.APIExists("ReaPack_ProcessQueue") then
      reaper.ReaPack_ProcessQueue(true)
    end
    if sync_cmd and sync_cmd ~= 0 then
      reaper.Main_OnCommand(sync_cmd, 0)
    end
  end
  reaper.defer(check_done)
end

reaper.defer(check_done)
