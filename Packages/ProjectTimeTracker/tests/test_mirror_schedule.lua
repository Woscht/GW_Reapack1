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
  if not c then
    print("FAIL " .. m)
    fails = fails + 1
  end
end

expect(M.should_run(0, 299, 300) == false, "before interval")
expect(M.should_run(0, 300, 300) == true, "at interval")
expect(M.should_run(100, 400, 300) == true, "elapsed interval")
expect(M.should_run(100, 350, 300) == false, "not yet elapsed")
expect(M.should_run(0, 1000, 0) == false, "zero interval")
expect(M.should_run(nil, 500, 300) == true, "nil last_ts")

return fails
