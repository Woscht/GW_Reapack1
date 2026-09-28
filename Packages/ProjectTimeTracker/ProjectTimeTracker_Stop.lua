-- @description ProjectTimeTracker Stop Action
-- @version 1.0.0
-- @author audiocoder
-- @noindex


-- Stop action: flips the ExtState flag to "0". The live tracker instance (running
-- via defer) picks it up on its next poll and writes script_stop with totals.
-- Because this script never defers, REAPER never shows the task-control dialog.

local was = reaper.GetExtState("ProjectTimeTracker", "running")
reaper.SetExtState("ProjectTimeTracker", "running", "0", true)
if was == "1" then
  reaper.ShowConsoleMsg("[PTT] Stop requested — tracker will stop within ~1.5s.\n")
else
  reaper.ShowConsoleMsg("[PTT] Tracker is not running.\n")
end
