PTT = PTT or {}
PTT.crash = {}
local M = PTT.crash

local function parse_field(line, key)
  return line:match('"' .. key .. '"%s*:%s*"([^"]*)"')
      or line:match('"' .. key .. '"%s*:%s*([%d%.%-]+)')
end

local ACTIVITY_EVENTS = {
  heartbeat = true,
  checkpoint = true,
  session_start = true,
  session_end = true,
  rec_start = true,
  rec_stop = true,
  rec_session_end = true,
  activity = true,
}

function M.recover(log_text)
  local open_wall = nil
  local open_rec = nil
  local last_activity_ts = nil
  local last_wall_span = nil
  local last_rec_accum = nil

  for line in (log_text or ""):gmatch("([^\n]+)") do
    local ev = parse_field(line, "event")
    local ts = parse_field(line, "ts")
    local sid = parse_field(line, "session_id")
    if ACTIVITY_EVENTS[ev] and ts then
      last_activity_ts = ts
    end
    if ev == "session_start" then
      open_wall = sid
      last_wall_span = 0
    elseif ev == "session_end" or (ev == "crash_close" and parse_field(line, "close_event") == "session_end") then
      open_wall = nil
    elseif ev == "rec_start" then
      open_rec = sid
      last_rec_accum = tonumber(parse_field(line, "rec_accum")) or 0
    elseif ev == "rec_session_end" or ev == "rec_stop" then
      open_rec = nil
    end
    local sa = tonumber(parse_field(line, "span_accum"))
    if sa then last_wall_span = sa end
    local ra = tonumber(parse_field(line, "rec_accum"))
    if ra then last_rec_accum = ra end
  end

  local actions = {}
  if open_wall then
    actions[#actions + 1] = {
      event = "crash_close",
      close_event = "session_end",
      session_id = open_wall,
      ts = last_activity_ts,
      span_accum = last_wall_span or 0,
    }
  end
  if open_rec then
    actions[#actions + 1] = {
      event = "crash_close",
      close_event = "rec_session_end",
      session_id = open_rec,
      ts = last_activity_ts,
      rec_accum = last_rec_accum or 0,
    }
  end
  return { actions = actions }
end
