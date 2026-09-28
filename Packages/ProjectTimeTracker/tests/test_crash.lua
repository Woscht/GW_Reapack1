local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("crash")
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local clean = [[
{"ts":"2026-01-01T10:00:00.000Z","event":"session_start","session_id":"wall_1"}
{"ts":"2026-01-01T10:05:00.000Z","event":"session_end","session_id":"wall_1","span_accum":300}
]]
local r = PTT.crash.recover(clean)
expect(#r.actions == 0, "clean log no actions")

local open = [[
{"ts":"2026-01-01T10:00:00.000Z","event":"session_start","session_id":"wall_1"}
{"ts":"2026-01-01T10:02:00.000Z","event":"heartbeat","session_id":"wall_1"}
{"ts":"2026-01-01T10:03:30.000Z","event":"heartbeat","session_id":"wall_1"}
]]
r = PTT.crash.recover(open)
expect(#r.actions == 1, "one crash_close")
expect(r.actions[1].event == "crash_close", "crash_close event")
expect(r.actions[1].close_event == "session_end", "closes wall")
expect(r.actions[1].ts == "2026-01-01T10:03:30.000Z", "last activity ts")
expect(r.actions[1].ts ~= nil and not r.actions[1].ts:find("15:"), "not wall clock now")

return fails
