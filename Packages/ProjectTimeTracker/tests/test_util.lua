local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("util")
local u = PTT.util
local fails = 0
local function expect(c, m)
  if not c then
    print("FAIL " .. m)
    fails = fails + 1
  end
end

expect(u.IDLE_GRACE_S == 120, "idle grace")
expect(u.SESSION_GAP_S == 900, "session gap")
expect(u.HEARTBEAT_S == 30, "heartbeat")
expect(u.POLL_S == 1.5, "poll")
expect(u.REC_GAP_S == 900, "rec gap")

local mid = u.machine_id({
  get_os = function() return "Other" end,
  popen_hostname = function() return nil end,
  getenv = function(k)
    if k == "COMPUTERNAME" then return "STUDIO-A" end
  end,
})
expect(mid == "STUDIO-A", "machine hostname win-style")
expect(not mid:find("%d%d%d%d"), "no pid-looking suffix required")

local js = u.json_encode({ event = "heartbeat", rec_accum = 1.5, ok = true })
expect(js:find('"event":"heartbeat"') ~= nil, "json event")
expect(js:find('"ok":true') ~= nil, "json bool")
expect(js:find("1%.5") ~= nil or js:find('"rec_accum":1.5') ~= nil, "json number")

local iso = u.now_iso(function() return 1.123 end)
expect(iso:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$") ~= nil, "iso format")

return fails
