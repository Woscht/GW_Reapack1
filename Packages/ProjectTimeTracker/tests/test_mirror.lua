local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("mirror")
local M = PTT.mirror

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(M.dest_path("/share/timelogs", "ABC123") == "/share/timelogs/ABC123.timelog.jsonl", "dest_path")
expect(M.dest_path("/share/timelogs/", "G") == "/share/timelogs/G.timelog.jsonl", "dest_path strip slash")

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
    exists = function(path)
      local f = io.open(path, "r")
      if f then f:close(); return true end
      return false
    end,
  }
end

local tmp = "/tmp/ptt_mirror_test"
os.execute('rm -rf "' .. tmp .. '" && mkdir -p "' .. tmp .. '/central"')
local fs = real_fs()
local src = tmp .. "/local/GUID1.timelog.jsonl"
os.execute('mkdir -p "' .. tmp .. '/local"')
local dest = tmp .. "/central/GUID1.timelog.jsonl"

local function write_src(text)
  local f = assert(io.open(src, "w"))
  f:write(text)
  f:close()
end

write_src('{"event":"a"}\n')
local ok, err = M.atomic_copy(src, dest, fs)
expect(ok == true and err == nil, "copy creates dest")
expect(fs.exists(dest), "dest exists")
local f = assert(io.open(dest, "r"))
local body = f:read("*a")
f:close()
expect(body == '{"event":"a"}\n', "dest content")

write_src('{"event":"b"}\n')
ok, err = M.atomic_copy(src, dest, fs)
expect(ok == true and err == nil, "second copy ok")
f = assert(io.open(dest, "r"))
body = f:read("*a")
f:close()
expect(body == '{"event":"b"}\n', "second copy replaces")
expect(not fs.exists(dest .. ".tmp"), "no tmp left on success")

ok, err = M.atomic_copy(tmp .. "/no_such_file.jsonl", dest, fs)
expect(ok == true and err == "skip", "missing src skips")

write_src("")
ok, err = M.atomic_copy(src, dest, fs)
expect(ok == true and err == "skip", "empty src skips")

return fails
