local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("untitled")
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local p = PTT.untitled.temp_path("/tmp/ptt_res", 42)
expect(p == "/tmp/ptt_res/PTT_untitled_42.timelog.jsonl", "temp path")

local base = "/tmp/ptt_untitled_test"
os.execute("rm -rf " .. base .. " && mkdir -p " .. base)
local temp = base .. "/temp.jsonl"
local dest = base .. "/dest.jsonl"
local tf = assert(io.open(temp, "w")); tf:write('{"event":"a"}\n'); tf:close()
local df = assert(io.open(dest, "w")); df:write('{"event":"b"}\n'); df:close()

local ok = PTT.untitled.migrate(temp, dest)
expect(ok == true, "migrate ok")
local out = assert(io.open(dest, "r")):read("*a")
expect(out:find('"event":"b"') ~= nil and out:find('"event":"a"') ~= nil, "appended")
expect(io.open(temp, "r") == nil, "temp removed")

return fails
