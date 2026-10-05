local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("office_opt")
load_mod("mirror")
load_mod("notes_ui")

local O = PTT.office_opt
local M = PTT.mirror
local N = PTT.notes_ui

local fails = 0
local function expect(c, msg)
  if not c then print("FAIL " .. msg); fails = fails + 1 end
end

-- Fake reaper ExtState store
local store = {}
local fake = {
  GetProjExtState = function(_, ns, key)
    local v = store[ns .. "\0" .. key]
    if v == nil then return 0, "" end
    return 1, v
  end,
  SetProjExtState = function(_, ns, key, val)
    if val == nil or val == "" then
      store[ns .. "\0" .. key] = nil
    else
      store[ns .. "\0" .. key] = tostring(val)
    end
  end,
}

expect(O.is_opted_out(fake) == false, "default not opted out")
expect(O.set_opted_out(fake, true) == true, "set true")
expect(O.is_opted_out(fake) == true, "reads true")
expect(O.toggle(fake) == false, "toggle off")
expect(O.is_opted_out(fake) == false, "after toggle off")
expect(O.toggle(fake) == true, "toggle on")
expect(O.is_opted_out_ctx({ office_opted_out = true }) == true, "ctx override true")
expect(O.is_opted_out_ctx({ office_opted_out = false, reaper = fake }) == false, "ctx override false")

-- Mirror skips when opted out
local tmp = "/tmp/ptt_office_opt_mirror"
os.execute('rm -rf "' .. tmp .. '" && mkdir -p "' .. tmp .. '/local" "' .. tmp .. '/central"')
local src = tmp .. "/local/G.timelog.jsonl"
local dest = tmp .. "/central/G.timelog.jsonl"
local f = assert(io.open(src, "w")); f:write('{"event":"a"}\n'); f:close()
local fs = {
  read_all = function(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a"); fh:close(); return data
  end,
  write_all = function(path, data)
    local fh, err = io.open(path, "wb")
    if not fh then return false, err end
    fh:write(data); fh:close(); return true
  end,
  rename = function(a, b)
    local ok, err = os.rename(a, b)
    return ok, err
  end,
  remove = function(path) os.remove(path); return true end,
  mkdir_p = function() return true end,
}
local ctx = {
  cfg = { mirror_enabled = true, central_timelogs_dir = tmp .. "/central", mirror_interval_s = 300 },
  ident = { guid = "G" },
  writer = { path = src },
  office_opted_out = true,
  last_mirror_ts = 0,
}
M.maybe_mirror(ctx, { force = true, fs = fs, now = 1000 })
local exists = io.open(dest, "r")
expect(exists == nil, "mirror skipped when opted out")
if exists then exists:close() end

ctx.office_opted_out = false
M.maybe_mirror(ctx, { force = true, fs = fs, now = 2000 })
exists = io.open(dest, "r")
expect(exists ~= nil, "mirror runs when not opted out")
if exists then exists:close() end

local ok_h, reason = M.maybe_hydrate({
  cfg = { mirror_enabled = true, central_timelogs_dir = tmp .. "/central" },
  ident = { guid = "G" },
  writer = { path = src },
  office_opted_out = true,
}, { fs = fs })
expect(ok_h == false and reason == "office_opt_out", "hydrate skipped")

local ok_n, reason_n = N.maybe_auto_open({
  cfg = { notes_ui_base_url = "http://x", notes_auto_open = true },
  ident = { guid = "G", saved = true },
  office_opted_out = true,
  now = function() return 1 end,
  notes_last_open_ts = {},
}, {
  http_get = function() return '{"blocks":1,"missing":1}' end,
  open_fn = function() error("must not open") end,
})
expect(ok_n == false and reason_n == "office_opt_out", "notes auto-open skipped")

return fails
