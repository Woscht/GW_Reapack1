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
local function expect(c, m) if not c then print("FAIL "..m); fails = fails + 1 end end

expect(M.should_force_on_save(true, false, 100, 0, 30) == true, "first dirty→clean")
expect(M.should_force_on_save(true, false, 110, 100, 30) == false, "within debounce")
expect(M.should_force_on_save(true, false, 140, 100, 30) == true, "after debounce")
expect(M.should_force_on_save(false, false, 200, 0, 30) == false, "already clean")
expect(M.should_force_on_save(true, true, 200, 0, 30) == false, "still dirty")
expect(M.should_force_on_save(false, true, 200, 0, 30) == false, "became dirty")
return fails
