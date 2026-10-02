local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("path_migrate")
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local base = "/tmp/ptt_path_migrate_test"
os.execute("rm -rf " .. base)
os.execute("mkdir -p " .. base .. "/old " .. base .. "/new/timetracker")
local old_path = base .. "/old/GUID1.timelog.jsonl"
local f = assert(io.open(old_path, "w"))
f:write('{"event":"session_start"}\n')
f:close()

expect(PTT.path_migrate.LOCAL_SUBDIR == "timetracker", "subdir name")
expect(
  PTT.path_migrate.local_log_path(base .. "/new", "GUID1")
    == base .. "/new/timetracker/GUID1.timelog.jsonl",
  "local_log_path"
)

local ops = {}
local result = PTT.path_migrate.carry(old_path, base .. "/new", "GUID1", {
  exists = function(p)
    local x = io.open(p, "r"); if x then x:close(); return true end; return false
  end,
  copy = function(src, dst)
    ops[#ops + 1] = "copy"
    local i = assert(io.open(src, "r")); local d = i:read("*a"); i:close()
    os.execute('mkdir -p "' .. dst:match("^(.+)/[^/]+$") .. '"')
    local o = assert(io.open(dst, "w")); o:write(d); o:close()
  end,
  rename = function(src, dst)
    ops[#ops + 1] = "rename"
    assert(os.rename(src, dst))
  end,
})

expect(result.new_path == base .. "/new/timetracker/GUID1.timelog.jsonl", "new path")
expect(result.bak_path == old_path .. ".bak", "bak path")
expect(ops[1] == "copy" and ops[2] == "rename", "copy then rename")
local nf = io.open(result.new_path, "r")
expect(nf ~= nil, "new exists")
if nf then nf:close() end
local bf = io.open(result.bak_path, "r")
expect(bf ~= nil, "bak exists")
if bf then bf:close() end
expect(io.open(old_path, "r") == nil, "old gone")

-- Same path must not copy/rename (would truncate/break the live log)
local same = PTT.path_migrate.carry(result.new_path, base .. "/new", "GUID1", {
  exists = function() return true end,
  copy = function() error("copy should not run") end,
  rename = function() error("rename should not run") end,
})
expect(same.skipped == true and same.same_path == true, "same path skipped")

return fails
