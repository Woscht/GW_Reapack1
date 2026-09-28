local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("util")
load_mod("writer")

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local tmp = "/tmp/ptt_writer_test"
os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
local path = tmp .. "/log.jsonl"

local w = PTT.writer.new({ path = path, json_encode = PTT.util.json_encode })
local ok = w:append({ event = "heartbeat", n = 1 })
expect(ok == true, "append ok")
local f = assert(io.open(path, "r"))
local body = f:read("*a")
f:close()
expect(body:find('"event":"heartbeat"') ~= nil, "line written")

-- fail then succeed via custom io_open
local attempts = 0
local real_open = io.open
local w2 = PTT.writer.new({
  path = tmp .. "/buf.jsonl",
  json_encode = PTT.util.json_encode,
  max_retries = 1,
  io_open = function(p, mode)
    attempts = attempts + 1
    if attempts == 1 then return nil, "simulated fail" end
    return real_open(p, mode)
  end,
})
ok = w2:append({ event = "session_start" })
expect(ok == false, "first append fails")
expect(#w2.buffer == 1, "buffered")
ok = w2:append({ event = "heartbeat" })
expect(ok == true, "later append ok")
expect(#w2.buffer == 0, "buffer drained")

return fails
