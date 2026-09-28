local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("util")
load_mod("session_rec")
local R = PTT.session_rec
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local s = R.new_state()
local out = R.tick(s, { now = 100, is_recording = true, dt = 1.5 })
expect(out.state.open == true, "opens on record")
expect(out.events[1].event == "rec_start", "rec_start")
expect(out.state.rec_accum == 1.5, "accum while rec")

out = R.tick(out.state, { now = 101.5, is_recording = true, dt = 1.5 })
expect(out.state.rec_accum == 3.0, "more rec")
expect(#out.events == 0, "no second start")

-- stop recording but within gap
out = R.tick(out.state, { now = 200, is_recording = false, dt = 1.5 })
expect(out.state.open == true, "open during take gap")
expect(out.state.rec_accum == 3.0, "no accum when not recording")

-- gap close
local accum = out.state.rec_accum
out = R.tick(out.state, { now = 101.5 + 900, is_recording = false, dt = 0 })
expect(out.state.open == false, "closed after rec gap")
expect(out.events[1].event == "rec_session_end", "rec_session_end")
expect(out.events[1].rec_accum == accum, "accum in end")

return fails
