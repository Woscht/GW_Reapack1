PTT = PTT or {}
PTT.util = PTT.util or {}
local M = PTT.util

M.POLL_S = 1.5
M.IDLE_GRACE_S = 120
M.SESSION_GAP_S = 900
M.REC_GAP_S = 900
M.HEARTBEAT_S = 180

function M.now_iso(time_precise_fn)
  local t = os.date("!*t")
  local ms = 0
  if time_precise_fn then
    ms = math.floor((time_precise_fn() % 1) * 1000)
  end
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    t.year, t.month, t.day, t.hour, t.min, t.sec, ms)
end

local function json_escape(s)
  s = tostring(s)
  return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

function M.json_encode(t)
  local parts = {}
  for k, v in pairs(t) do
    local key = '"' .. json_escape(k) .. '"'
    local val
    if type(v) == "number" then
      val = string.format("%.6f", v):gsub("%.?0+$", "")
      if val == "" or val == "-" then val = "0" end
    elseif type(v) == "boolean" then
      val = v and "true" or "false"
    elseif type(v) == "table" then
      val = "{" .. M.json_encode(v) .. "}"
    elseif v == nil then
      val = "null"
    else
      val = '"' .. json_escape(v) .. '"'
    end
    parts[#parts + 1] = key .. ":" .. val
  end
  return table.concat(parts, ",")
end

function M.machine_id(env)
  env = env or {}
  local host
  local osname = env.get_os and env.get_os() or ""
  if osname:find("OSX") or osname:find("mac") then
    host = env.popen_hostname and env.popen_hostname() or "unknown-mac"
  else
    host = (env.getenv and env.getenv("COMPUTERNAME"))
      or (env.popen_hostname and env.popen_hostname())
      or "unknown-host"
  end
  host = (host or "unknown-host"):gsub("%s+", "")
  return host
end
