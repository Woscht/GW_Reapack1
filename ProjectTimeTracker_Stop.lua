-- @description ProjectTimeTracker Stop Action
-- @version 2.0.0
-- @author audiocoder
-- @noindex

-- Emergency stop: flips ExtState so the always-on tracker exits its defer loop.

local was = reaper.GetExtState("ProjectTimeTracker", "running")
reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
if was == "1" then
  reaper.ShowConsoleMsg("[PTT] Stop requested — tracker will stop within ~1.5s.\n")
else
  reaper.ShowConsoleMsg("[PTT] Tracker is not running.\n")
end
