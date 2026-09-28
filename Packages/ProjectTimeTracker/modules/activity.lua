PTT = PTT or {}
PTT.activity = {}
local M = PTT.activity

function M.classify(prev, sample)
  prev = prev or {}
  local ps = sample.play_state or 0
  local is_play = (ps % 2) == 1
  local is_pause = math.floor(ps / 2) % 2 == 1
  local is_rec = math.floor(ps / 4) % 2 == 1

  local cursor_moved =
    (sample.edit_cursor ~= prev.edit_cursor) or
    (sample.play_cursor ~= prev.play_cursor)
  local dirty_changed = (sample.is_dirty ~= prev.is_dirty) and sample.is_dirty == true
  local undo_changed = sample.undo_count ~= prev.undo_count
  local sel_changed = sample.sel_fingerprint ~= prev.sel_fingerprint
  local interaction = cursor_moved or dirty_changed or undo_changed or sel_changed

  local active, reason = false, "idle"
  if is_rec then
    active, reason = true, "record"
  elseif is_play then
    active, reason = true, "play"
  elseif is_pause and not interaction then
    active, reason = false, "pause"
  elseif interaction then
    active, reason = true, "interaction"
  else
    active, reason = false, "idle"
  end

  local next_prev = {
    edit_cursor = sample.edit_cursor,
    play_cursor = sample.play_cursor,
    is_dirty = sample.is_dirty,
    undo_count = sample.undo_count,
    sel_fingerprint = sample.sel_fingerprint,
  }
  return { active = active, reason = reason, next_prev = next_prev }
end
