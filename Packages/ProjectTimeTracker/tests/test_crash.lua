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
expect((r.actions[1].span_accum or 0) == 0, "old heartbeats without span → 0")

local with_progress = [[
{"ts":"2026-01-01T10:00:00.000Z","event":"session_start","session_id":"wall_1"}
{"ts":"2026-01-01T10:00:00.000Z","event":"rec_start","session_id":"rec_1","rec_accum":0}
{"ts":"2026-01-01T10:03:00.000Z","event":"heartbeat","session_id":"wall_1","span_accum":180,"rec_accum":180}
{"ts":"2026-01-01T10:05:00.000Z","event":"checkpoint","session_id":"wall_1","span_accum":300,"rec_accum":300}
]]
r = PTT.crash.recover(with_progress)
expect(#r.actions == 2, "wall+rec crash_close")
local wall_a, rec_a
for _, a in ipairs(r.actions) do
  if a.close_event == "session_end" then wall_a = a end
  if a.close_event == "rec_session_end" then rec_a = a end
end
expect(wall_a ~= nil and wall_a.span_accum == 300, "wall from checkpoint span")
expect(rec_a ~= nil and rec_a.rec_accum == 300, "rec from checkpoint accum")
expect(wall_a.ts == "2026-01-01T10:05:00.000Z", "checkpoint updates activity ts")

return fails
