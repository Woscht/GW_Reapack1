local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("report")
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local log = [[
{"event":"session_end","span_accum":120.5}
{"event":"session_end","span_accum":60}
{"event":"rec_session_end","rec_accum":40}
{"event":"crash_close","close_event":"rec_session_end","rec_accum":10}
]]
local sum = PTT.report.sum_log(log)
expect(sum.session_span_s == 180.5, "session sum")
expect(sum.rec_rolling_s == 50, "rec sum")

local md = PTT.report.to_markdown(sum, { project_name = "Show", project_guid = "ABC" })
expect(md:find("Session%-Span") ~= nil, "md session")
expect(md:find("Rec%-Rolling") ~= nil, "md rec")

local csv = PTT.report.to_csv(sum, { project_name = "Show", project_guid = "ABC" })
expect(csv:find("session_span_s") ~= nil, "csv header")
expect(csv:find("180.500") ~= nil, "csv value")

return fails
