-- @description ProjectTimeTracker Stop Action
-- @version 2.1.11
-- @author audiocoder
-- @noindex

-- Emergency stop: flips ExtState so the always-on tracker exits its defer loop.

local was = reaper.GetExtState("ProjectTimeTracker", "running")
-- Session-only (must not persist — see bootstrap.start_or_toggle_stop).
reaper.SetExtState("ProjectTimeTracker", "running", "0", false)
if reaper.DeleteExtState then
  reaper.DeleteExtState("ProjectTimeTracker", "running", true)
end
if was == "1" then
  reaper.ShowConsoleMsg("[PTT] Stop requested — tracker will stop within ~1.5s.\n")
else
  reaper.ShowConsoleMsg("[PTT] Tracker is not running.\n")
end
