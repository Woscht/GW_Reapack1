local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("startup_on")
local S = PTT.startup_on

local fails = 0
local function expect(c, msg)
  if not c then
    print("FAIL " .. msg)
    fails = fails + 1
  end
end

expect(S.startup_file("/res") == "/res/Scripts/__startup.lua"
  or S.startup_file("/res") == "/res\\Scripts\\__startup.lua", "startup path")
expect(S.startup_file(nil) == nil, "nil resource")

local block = S.block_for_path("/pkg/ProjectTimeTracker.lua")
expect(type(block) == "string" and block:find(S.BEGIN, 1, true), "block begin")
expect(block:find("ProjectTimeTracker.lua", 1, true) ~= nil, "block path")
expect(S.is_enabled(block) == true, "enabled on block")
expect(S.is_enabled("-- other") == false, "not enabled")

local with_other = "-- keep me\n" .. block .. "\n-- after\n"
local stripped, removed = S.strip_block(with_other)
expect(removed == true, "strip removed")
expect(stripped:find(S.BEGIN, 1, true) == nil, "strip no begin")
expect(stripped:find("keep me", 1, true) ~= nil, "strip keeps before")
expect(stripped:find("after", 1, true) ~= nil, "strip keeps after")

local ensured = select(1, S.ensure_block("-- keep\n", "/x/ProjectTimeTracker.lua"))
expect(ensured:find("keep", 1, true) ~= nil, "ensure keep")
expect(S.is_enabled(ensured), "ensure enabled")

-- Fake FS for enable/disable
local files = {}
local function fake_open(path, mode)
  mode = mode or "r"
  if mode:find("r") and not mode:find("w") then
    if files[path] == nil then
      return nil
    end
    local data = files[path]
    local i = 1
    return {
      read = function(_, what)
        if what == "*a" then
          local out = data:sub(i)
          i = #data + 1
          return out
        end
        return nil
      end,
      close = function() end,
    }
  end
  if mode:find("w") then
    local chunks = {}
    return {
      write = function(_, s)
        chunks[#chunks + 1] = s
      end,
      close = function()
        files[path] = table.concat(chunks)
      end,
    }
  end
  return nil
end

local res = "/tmp/ptt_res_fake"
local startup = S.startup_file(res)
local ptt = "/tmp/ptt_pkg/ProjectTimeTracker.lua"
files[startup] = "-- preexisting\n"

local ok, reason = S.enable({
  resource_path = res,
  ptt_path = ptt,
  io_open = fake_open,
})
expect(ok == true and reason == "enabled", "enable first: " .. tostring(reason))
expect(S.is_enabled(files[startup]), "file enabled")
expect(files[startup]:find("preexisting", 1, true) ~= nil, "preserve preexisting")

ok, reason = S.enable({
  resource_path = res,
  ptt_path = ptt,
  io_open = fake_open,
})
expect(ok == true and (reason == "already" or reason == "enabled"), "enable idempotent")

ok, reason = S.disable({
  resource_path = res,
  io_open = fake_open,
})
expect(ok == true and reason == "disabled", "disable: " .. tostring(reason))
expect(not S.is_enabled(files[startup]), "file disabled")
expect(files[startup]:find("preexisting", 1, true) ~= nil, "disable keeps other")

ok, reason = S.disable({
  resource_path = res,
  io_open = fake_open,
})
expect(ok == true and reason == "absent", "disable absent")

print(string.format("test_startup_on fails=%d", fails))
return fails
