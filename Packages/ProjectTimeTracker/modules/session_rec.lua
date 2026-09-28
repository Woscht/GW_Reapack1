PTT = PTT or {}
PTT.session_rec = {}
local M = PTT.session_rec
local U = PTT.util

function M.new_state()
  return { open = false, session_id = nil, rec_accum = 0, last_take_ts = nil }
end

function M.tick(state, opts)
  local now, rec, dt = opts.now, opts.is_recording, opts.dt or 0
  local gap = (U and U.REC_GAP_S) or 900
  local events = {}
  if rec then
    if not state.open then
      state.open = true
      state.session_id = string.format("rec_%d", math.floor(now))
      state.rec_accum = 0
      events[#events + 1] = { event = "rec_start", session_id = state.session_id, ts_now = now }
    end
    state.rec_accum = state.rec_accum + dt
    state.last_take_ts = now
    return { state = state, events = events }
  end
  if state.open and state.last_take_ts and (now - state.last_take_ts) >= gap then
    events[#events + 1] = {
      event = "rec_session_end",
      session_id = state.session_id,
      rec_accum = state.rec_accum,
      ts_now = now,
    }
    state.open = false
    state.session_id = nil
    state.rec_accum = 0
    state.last_take_ts = nil
  end
  return { state = state, events = events }
end
