local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("util")
load_mod("session_wall")
local W = PTT.session_wall
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local s = W.new_state()
local out = W.tick(s, { now = 1000, active = true, dt = 1.5 })
expect(out.state.open == true, "opens on activity")
expect(#out.events == 1 and out.events[1].event == "session_start", "session_start")
expect(out.state.span_accum == 1.5, "accum active")

out = W.tick(out.state, { now = 1001.5, active = true, dt = 1.5 })
expect(out.state.span_accum == 3.0, "more active")
expect(#out.events == 0, "no extra start")

-- idle within grace: still accumulates
out = W.tick(out.state, { now = 1100, active = false, dt = 1.5 }) -- 98.5s idle from last_activity 1001.5
expect(out.state.open == true, "still open in grace")
expect(out.state.span_accum > 3.0, "grace accumulates")

-- jump past grace but before gap: no further accumulate from this tick's perspective
-- set last_activity far: simulate by ticking with now = last+200
local last = out.state.last_activity_ts
local span_before = out.state.span_accum
out = W.tick(out.state, { now = last + 200, active = false, dt = 1.5 })
expect(out.state.span_accum == span_before, "past grace no accum")
expect(out.state.open == true, "still open before gap")

-- gap close at 900s idle
span_before = out.state.span_accum
out = W.tick(out.state, { now = last + 900, active = false, dt = 1.5 })
expect(out.state.open == false, "closed after gap")
expect(#out.events == 1 and out.events[1].event == "session_end", "session_end")
expect(out.events[1].span_accum == span_before, "span in end event")

-- new activity starts new session
out = W.tick(out.state, { now = last + 1000, active = true, dt = 1.0 })
expect(out.state.open == true, "new session")
expect(out.events[1].event == "session_start", "new start")

return fails
