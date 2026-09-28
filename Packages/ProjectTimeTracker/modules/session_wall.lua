PTT = PTT or {}
PTT.session_wall = {}
local M = PTT.session_wall
local U = PTT.util

local function new_id(now)
  return string.format("wall_%d", math.floor(now))
end

function M.new_state()
  return {
    session_id = nil,
    span_accum = 0,
    last_activity_ts = nil,
    open = false,
  }
end

function M.tick(state, opts)
  local now, active, dt = opts.now, opts.active, opts.dt or 0
  local events = {}
  local grace = (U and U.IDLE_GRACE_S) or 120
  local gap = (U and U.SESSION_GAP_S) or 900

  if active then
    if not state.open then
      state.open = true
      state.session_id = new_id(now)
      state.span_accum = 0
      events[#events + 1] = { event = "session_start", session_id = state.session_id, ts_now = now }
    end
    state.span_accum = state.span_accum + dt
    state.last_activity_ts = now
    return { state = state, events = events }
  end

  if not state.open then
    return { state = state, events = events }
  end

  local last = state.last_activity_ts or now
  local idle_for = now - last
  if idle_for <= grace then
    state.span_accum = state.span_accum + dt
  end
  if idle_for >= gap then
    events[#events + 1] = {
      event = "session_end",
      session_id = state.session_id,
      span_accum = state.span_accum,
      ts_now = now,
    }
    state.open = false
    state.session_id = nil
    state.span_accum = 0
    state.last_activity_ts = nil
  end
  return { state = state, events = events }
end
