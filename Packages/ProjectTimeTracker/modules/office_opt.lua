PTT = PTT or {}
PTT.office_opt = PTT.office_opt or {}
local M = PTT.office_opt

M.EXT_NS = "ProjectTimeTracker"
M.EXT_KEY = "office_opt_out"

--- True when the current project opted out of office mirror / notes reminder.
function M.is_opted_out(reaper_api)
  reaper_api = reaper_api or reaper
  if not reaper_api or type(reaper_api.GetProjExtState) ~= "function" then
    return false
  end
  local ret, v = reaper_api.GetProjExtState(0, M.EXT_NS, M.EXT_KEY)
  if ret ~= 1 or v == nil then
    return false
  end
  v = tostring(v)
  return v == "1" or v == "true" or v == "yes"
end

--- Prefer explicit ctx.office_opted_out in tests; else read project ExtState.
function M.is_opted_out_ctx(ctx)
  if type(ctx) == "table" and ctx.office_opted_out ~= nil then
    return ctx.office_opted_out == true
  end
  return M.is_opted_out(ctx and ctx.reaper)
end

function M.set_opted_out(reaper_api, opted)
  reaper_api = reaper_api or reaper
  if not reaper_api or type(reaper_api.SetProjExtState) ~= "function" then
    return false
  end
  local value = opted and "1" or ""
  reaper_api.SetProjExtState(0, M.EXT_NS, M.EXT_KEY, value)
  return true
end

function M.toggle(reaper_api)
  local next_state = not M.is_opted_out(reaper_api)
  M.set_opted_out(reaper_api, next_state)
  return next_state
end
