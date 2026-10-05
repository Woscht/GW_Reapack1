local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("office_opt")
load_mod("notes_ui")
local N = PTT.notes_ui

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(N.rate_ok("G", 1000, {}, 1800) == true, "rate ok first open")
expect(N.rate_ok("G", 1000, { G = 500 }, 1800) == false, "rate blocked")
expect(N.rate_ok("G", 2500, { G = 500 }, 1800) == true, "rate ok after window")

expect(
  N.notes_url("http://host:3001/", "GUID1") == "http://host:3001/projects/GUID1/notes?src=reaper",
  "notes_url strip slash + src")
expect(
  N.notes_url("http://host:3001", "GUID1", "from=2026-10-01&to=2026-10-31")
    == "http://host:3001/projects/GUID1/notes?src=reaper&from=2026-10-01&to=2026-10-31",
  "notes_url with qs")
expect(
  N.status_url("http://host:3001/", "GUID1") == "http://host:3001/projects/GUID1/notes/status",
  "status_url")

local missing = N.fetch_missing(
  "http://x/status",
  function() return '{"blocks":3,"missing":1}' end)
expect(missing == 1, "fetch_missing parses")
expect(N.fetch_missing("http://x", function() return nil end) == nil, "fetch nil on empty")
expect(N.fetch_missing("http://x", function() error("boom") end) == nil, "fetch nil on error")

local opened = {}
local ctx = {
  cfg = { notes_ui_base_url = "http://office:3001", notes_auto_open = true },
  ident = { guid = "G1", saved = true },
  now = function() return 10000 end,
  notes_last_open_ts = {},
  reaper = {},
}
local ok, reason = N.maybe_auto_open(ctx, {
  http_get = function() return '{"blocks":5,"missing":2}' end,
  open_fn = function(url) opened[#opened + 1] = url end,
})
expect(ok == true and reason == "opened", "auto open when missing>0")
expect(opened[1] == "http://office:3001/projects/G1/notes?src=reaper", "opened correct url")
expect(ctx.notes_last_open_ts["G1"] == 10000, "recorded open ts")

ok, reason = N.maybe_auto_open(ctx, {
  now = 10001,
  http_get = function() return '{"blocks":5,"missing":2}' end,
  open_fn = function(url) opened[#opened + 1] = url end,
})
expect(ok == false and reason == "rate_limited", "rate limit blocks second open")

ok, reason = N.maybe_auto_open({
  cfg = { notes_ui_base_url = "http://office:3001", notes_auto_open = true },
  ident = { guid = "G2", saved = true },
  now = function() return 1 end,
  notes_last_open_ts = {},
}, {
  http_get = function() return '{"blocks":5,"missing":0}' end,
  open_fn = function() error("should not open") end,
})
expect(ok == false and reason == "complete", "no open when missing=0")

ok, reason = N.maybe_auto_open({
  cfg = { notes_ui_base_url = "http://office:3001", notes_auto_open = true },
  ident = { guid = "G3", saved = true },
  now = function() return 1 end,
  notes_last_open_ts = {},
}, {
  http_get = function() return nil end,
  open_fn = function() error("should not open on fail") end,
})
expect(ok == false and reason == "status_failed", "no open on status failure")

local man_opened = {}
ok, reason = N.open_manual({
  cfg = { notes_ui_base_url = "http://office:3001" },
  ident = { guid = "GM", saved = true },
  reaper = {},
}, {
  open_fn = function(url) man_opened[#man_opened + 1] = url end,
})
expect(ok == true and man_opened[1]:find("src=reaper") ~= nil, "manual always opens")

return fails
