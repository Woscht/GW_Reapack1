local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
-- bootstrap pulls util via PTT.util in run(); only need start_or_toggle_stop here
load_mod("util")
load_mod("bootstrap")
local B = PTT.bootstrap

local fails = 0
local function expect(c, msg)
  if not c then
    print("FAIL " .. msg)
    fails = fails + 1
  end
end

local store = {}
local function get_ext(ns, key)
  return store[ns .. "\0" .. key] or ""
end
local function set_ext(ns, key, val, persist)
  local k = ns .. "\0" .. key
  if val == nil or val == "" then
    store[k] = nil
  else
    store[k] = tostring(val)
  end
  store[k .. "\0persist"] = not not persist
end
local function del_ext(ns, key, persist)
  store[ns .. "\0" .. key] = nil
  store[ns .. "\0" .. key .. "\0persist"] = nil
  if persist then
    -- pretend disk cleared
  end
end

-- Cold start with poisoned persisted "running"=1 (old bug)
store["ProjectTimeTracker\0running"] = "1"
store["ProjectTimeTracker\0running\0persist"] = true
expect(B.start_or_toggle_stop(get_ext, set_ext, del_ext) == "start", "cold start despite poison")
expect(get_ext("ProjectTimeTracker", "running") == "1", "running set session")
expect(get_ext("ProjectTimeTracker", "_boot") == "1", "boot marked")

-- Second invoke same session = stop
expect(B.start_or_toggle_stop(get_ext, set_ext, del_ext) == "stop", "toggle stop")
expect(get_ext("ProjectTimeTracker", "running") == "0", "running cleared")

-- Third invoke starts again
expect(B.start_or_toggle_stop(get_ext, set_ext, del_ext) == "start", "start again")

print(string.format("test_bootstrap_startup fails=%d", fails))
return fails
