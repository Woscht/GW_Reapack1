-- tests for occupancy discard rules (no REAPER)
local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("occupancy")
local O = PTT.occupancy

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(O.should_discard(false, false) == true, "reference never dirty")
expect(O.should_discard(false, true) == true, "edited never saved / dirty leave")
expect(O.should_discard(true, true) == true, "saved then dirty DontSave")
expect(O.should_discard(true, false) == false, "saved and clean leave")

local tmp = os.tmpname()
local f = io.open(tmp, "w")
f:write('{"ts":"2026-10-06T10:00:00.000Z","event":"script_start"}\n')
f:write('{"ts":"2026-10-06T11:00:00.000Z","event":"session_start"}\n')
f:write('{"ts":"2026-10-06T11:05:00.000Z","event":"session_end"}\n')
f:close()

local kept, removed = O.strip_events_since(tmp, "2026-10-06T11:00:00.000Z")
expect(kept == 1 and removed == 2, "strip counts")
local body = io.open(tmp, "r"):read("*a")
expect(body:find("script_start", 1, true) ~= nil, "kept early")
expect(body:find("session_start", 1, true) == nil, "removed occupancy")
os.remove(tmp)

local empty_n, empty_r = O.strip_events_since("/no/such/file", "2026-10-06T11:00:00.000Z")
expect(empty_n == 0 and empty_r == 0, "missing file")

return fails
