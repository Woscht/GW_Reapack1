-- Minimal test runner for pure modules (no REAPER).
local function script_dir()
  local src = debug.getinfo(1, "S").source:match("^@(.+)$")
  return src:match("^(.*)/[^/]+$")
end

local dir = script_dir()
local fails = 0
local ran = 0

local handle = io.popen('ls "' .. dir .. '"/test_*.lua 2>/dev/null')
local list = handle:read("*a") or ""
handle:close()

for file in list:gmatch("([^\n]+)") do
  local name = file:match("([^/]+)$")
  if name and name ~= "run_tests.lua" then
    print("==> " .. name)
    local chunk, err = loadfile(dir .. "/" .. name)
    if not chunk then
      print("LOAD FAIL: " .. tostring(err))
      fails = fails + 1
    else
      local ok, n = pcall(chunk)
      if not ok then
        print("ERROR: " .. tostring(n))
        fails = fails + 1
      else
        n = tonumber(n) or 0
        fails = fails + n
        ran = ran + 1
      end
    end
  end
end

print(string.format("Done. files=%d fails=%d", ran, fails))
os.exit(fails == 0 and 0 or 1)
