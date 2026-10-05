local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("office_opt")
load_mod("mirror")
local M = PTT.mirror

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(
  M.notes_dest_path("/share/timelogs", "ABC") == "/share/timelogs/ABC.notes.jsonl",
  "notes_dest_path")
expect(
  M.notes_src_path("/p/timetracker/ABC.timelog.jsonl") == "/p/timetracker/ABC.notes.jsonl",
  "notes_src_path")

local function real_fs()
  return {
    read_all = function(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local data = f:read("*a")
      f:close()
      return data
    end,
    write_all = function(path, data)
      local f, err = io.open(path, "wb")
      if not f then return false, err or "write failed" end
      f:write(data)
      f:close()
      return true
    end,
    rename = function(a, b)
      local ok, err = os.rename(a, b)
      if ok then return true end
      return false, err or "rename failed"
    end,
    remove = function(path)
      os.remove(path)
      return true
    end,
    mkdir_p = function(dir)
      os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
      return true
    end,
  }
end

local tmp = "/tmp/ptt_mirror_notes_test"
os.execute('rm -rf "' .. tmp .. '" && mkdir -p "' .. tmp .. '/local" "' .. tmp .. '/central"')
local fs = real_fs()
local src = tmp .. "/local/GUID1.timelog.jsonl"
local notes_src = tmp .. "/local/GUID1.notes.jsonl"
local dest = tmp .. "/central/GUID1.timelog.jsonl"
local notes_dest = tmp .. "/central/GUID1.notes.jsonl"

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

write(src, '{"event":"a"}\n')
write(notes_src, '{"block_id":"x","text":"n1"}\n')
-- older central notes that should be replaced (even if longer) when local exists
write(notes_dest, '{"block_id":"x","text":"old1"}\n{"block_id":"y","text":"old2"}\n')

local ctx = {
  cfg = {
    mirror_enabled = true,
    central_timelogs_dir = tmp .. "/central",
    mirror_interval_s = 300,
  },
  ident = { guid = "GUID1", saved = true },
  writer = { path = src },
  last_mirror_ts = 0,
  now = function() return 1000 end,
}
M.maybe_mirror(ctx, { force = true, fs = fs, now = 1000 })

local f = assert(io.open(dest, "r"))
local tbody = f:read("*a"); f:close()
expect(tbody == '{"event":"a"}\n', "timelog mirrored")

f = assert(io.open(notes_dest, "r"))
local nbody = f:read("*a"); f:close()
expect(nbody == '{"block_id":"x","text":"n1"}\n', "notes overwritten without shrink guard")

-- missing local notes leaves central intact
os.remove(notes_src)
write(src, '{"event":"a"}\n{"event":"b"}\n')
write(notes_dest, '{"block_id":"keep","text":"central"}\n')
ctx.last_mirror_ts = 0
M.maybe_mirror(ctx, { force = true, fs = fs, now = 2000 })
f = assert(io.open(notes_dest, "r"))
nbody = f:read("*a"); f:close()
expect(nbody == '{"block_id":"keep","text":"central"}\n', "central notes kept when local missing")

return fails
