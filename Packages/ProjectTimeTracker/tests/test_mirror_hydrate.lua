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

expect(M.line_count(nil) == 0, "nil lines")
expect(M.line_count("") == 0, "empty lines")
expect(M.line_count('{"a":1}\n{"b":2}\n') == 2, "two lines")
expect(M.line_count('{"a":1}\n') == 1, "one line")

expect(M.should_overwrite_central('{"a"}\n{"b"}\n', '{"a"}\n') == true, "local longer ok")
expect(M.should_overwrite_central('{"a"}\n', '{"a"}\n{"b"}\n') == false, "central longer block")
expect(M.should_overwrite_central('{"a"}\n', nil) == true, "no central ok")
expect(M.should_overwrite_central("", '{"a"}\n') == false, "empty local block")
expect(M.should_overwrite_central('{"a"}\n', "") == true, "empty central ok")
expect(M.should_overwrite_central('{"a"}\n', '{"a"}\n') == true, "equal lines ok")

local tmp = "/tmp/ptt_mirror_hydrate_test"
os.execute('rm -rf "' .. tmp .. '" && mkdir -p "' .. tmp .. '/central" "' .. tmp .. '/local"')

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
    remove = function(path) os.remove(path); return true end,
    mkdir_p = function(dir)
      os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
      return true
    end,
  }
end

local fs = real_fs()
local local_path = tmp .. "/local/GUIDH.timelog.jsonl"
local central_path = tmp .. "/central/GUIDH.timelog.jsonl"

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Hydrate: missing local, central has history
write(central_path, '{"event":"old1"}\n{"event":"old2"}\n{"event":"old3"}\n')
os.remove(local_path)
local did, reason = M.hydrate_if_needed(local_path, central_path, fs)
expect(did == true and reason == "hydrated", "hydrate missing local")
local body = fs.read_all(local_path)
expect(body == '{"event":"old1"}\n{"event":"old2"}\n{"event":"old3"}\n', "hydrated content")

-- Hydrate: local shorter than central
write(local_path, '{"event":"newish"}\n')
write(central_path, '{"event":"c1"}\n{"event":"c2"}\n{"event":"c3"}\n')
did, reason = M.hydrate_if_needed(local_path, central_path, fs)
expect(did == true and reason == "hydrated", "hydrate shorter local")
expect(M.line_count(fs.read_all(local_path)) == 3, "local now 3 lines")

-- Hydrate: local already longer — no op
write(local_path, '{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n{"event":"d"}\n')
write(central_path, '{"event":"a"}\n')
did, reason = M.hydrate_if_needed(local_path, central_path, fs)
expect(did == false and reason == "local_ok", "no hydrate when local longer")
expect(M.line_count(fs.read_all(local_path)) == 4, "local unchanged")

-- maybe_mirror never-shrink: central longer must not be overwritten
write(local_path, '{"event":"short"}\n')
write(central_path, '{"event":"long1"}\n{"event":"long2"}\n{"event":"long3"}\n')
local central_before = fs.read_all(central_path)
local ctx = {
  cfg = { mirror_enabled = true, central_timelogs_dir = tmp .. "/central", mirror_interval_s = 1 },
  ident = { guid = "GUIDH" },
  writer = { path = local_path },
  last_mirror_ts = 0,
  now = function() return 1000 end,
  reaper = { ShowConsoleMsg = function() end },
}
M.maybe_mirror(ctx, { force = true, fs = fs, now = 1000 })
expect(fs.read_all(central_path) == central_before, "never shrink central")

-- maybe_mirror allows when local longer/equal
write(local_path, '{"event":"l1"}\n{"event":"l2"}\n{"event":"l3"}\n{"event":"l4"}\n')
M.maybe_mirror(ctx, { force = true, fs = fs, now = 2000 })
expect(M.line_count(fs.read_all(central_path)) == 4, "push when local longer")

-- maybe_hydrate via ctx
os.remove(local_path)
write(central_path, '{"event":"z1"}\n{"event":"z2"}\n')
local h_ok, h_reason = M.maybe_hydrate(ctx, { fs = fs })
expect(h_ok == true and h_reason == "hydrated", "maybe_hydrate ctx")
expect(M.line_count(fs.read_all(local_path)) == 2, "ctx hydrate wrote local")

return fails
