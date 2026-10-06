PTT = PTT or {}
PTT.notes_ui = PTT.notes_ui or {}
local M = PTT.notes_ui

M.DEFAULT_RATE_LIMIT_S = 1800

function M.rate_ok(guid, now, last_open_ts_by_guid, rate_limit_s)
  if not guid or guid == "" then
    return false
  end
  rate_limit_s = rate_limit_s or M.DEFAULT_RATE_LIMIT_S
  last_open_ts_by_guid = last_open_ts_by_guid or {}
  local last = last_open_ts_by_guid[guid]
  if last == nil or last == 0 then
    return true
  end
  return (now - last) >= rate_limit_s
end

function M.notes_url(base, guid, qs)
  base = tostring(base or ""):gsub("/+$", "")
  local url = base .. "/projects/" .. tostring(guid) .. "/notes?src=reaper"
  if type(qs) == "string" and qs ~= "" then
    if qs:sub(1, 1) == "?" or qs:sub(1, 1) == "&" then
      qs = qs:sub(2)
    end
    url = url .. "&" .. qs
  end
  return url
end

function M.status_url(base, guid, qs)
  base = tostring(base or ""):gsub("/+$", "")
  local url = base .. "/projects/" .. tostring(guid) .. "/notes/status"
  if type(qs) == "string" and qs ~= "" then
    if qs:sub(1, 1) == "?" then
      url = url .. qs
    else
      url = url .. "?" .. qs
    end
  end
  return url
end

function M.query_encode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%._%-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function M.fetch_status(status_url, http_get, timeout_s)
  timeout_s = timeout_s or 3
  if type(http_get) ~= "function" then
    return nil
  end
  local ok, body = pcall(http_get, status_url, timeout_s)
  if not ok or type(body) ~= "string" or body == "" then
    return nil
  end
  if not PTT.config or type(PTT.config.parse_json_object) ~= "function" then
    return nil
  end
  local obj = select(1, PTT.config.parse_json_object(body))
  if type(obj) ~= "table" or type(obj.missing) ~= "number" then
    return nil
  end
  if type(obj.prompt) ~= "table" then
    obj.prompt = {}
  end
  if type(obj.older_missing) ~= "number" then
    obj.older_missing = obj.missing
  end
  return obj
end

function M.fetch_missing(status_url, http_get, timeout_s)
  -- NFS status+reingest needs a little headroom beyond a bare localhost ping.
  timeout_s = timeout_s or 3
  if type(http_get) ~= "function" then
    return nil
  end
  local ok, body = pcall(http_get, status_url, timeout_s)
  if not ok or type(body) ~= "string" or body == "" then
    return nil
  end
  local missing = body:match('"missing"%s*:%s*(%d+)')
  if not missing then
    return nil
  end
  return tonumber(missing)
end

function M.default_http_get(url, timeout_s)
  timeout_s = timeout_s or 3
  -- curl is available on studio Linux/macOS; if missing, auto-open skips (nil).
  local cmd = string.format('curl -s -m %d %q 2>/dev/null', timeout_s, url)
  local h = io.popen(cmd)
  if not h then
    return nil
  end
  local body = h:read("*a")
  h:close()
  if not body or body == "" then
    return nil
  end
  return body
end

function M.open(url, reaper_api)
  if not url or url == "" then
    return false
  end
  reaper_api = reaper_api or reaper
  if reaper_api and type(reaper_api.CF_ShellExecute) == "function" then
    reaper_api.CF_ShellExecute(url)
    return true
  end
  local os_name = ""
  if reaper_api and type(reaper_api.GetOS) == "function" then
    os_name = tostring(reaper_api.GetOS() or "")
  end
  local cmd
  if os_name:find("Win") then
    cmd = 'start "" "' .. url:gsub('"', "") .. '"'
  elseif os_name:find("OSX") or os_name:lower():find("mac") then
    cmd = 'open "' .. url:gsub('"', '\\"') .. '"'
  else
    cmd = 'xdg-open "' .. url:gsub('"', '\\"') .. '" >/dev/null 2>&1 &'
  end
  os.execute(cmd)
  return true
end

--- Auto-open notes UI when undocumented blocks exist.
--- opts: now, http_get, open_fn, rate_limit_s, qs
function M.maybe_auto_open(ctx, opts)
  opts = opts or {}
  if not ctx or not ctx.cfg then
    return false, "no_ctx"
  end
  local cfg = ctx.cfg
  if cfg.notes_auto_open == false then
    return false, "disabled"
  end
  if PTT.office_opt and PTT.office_opt.is_opted_out_ctx(ctx) then
    return false, "office_opt_out"
  end
  local base = cfg.notes_ui_base_url or ""
  if base == "" then
    return false, "no_base"
  end
  local ident = ctx.ident or {}
  if not ident.saved then
    return false, "unsaved"
  end
  local guid = ident.guid or ""
  if guid == "" then
    return false, "no_guid"
  end
  local now = opts.now or (ctx.now and ctx.now()) or os.time()
  ctx.notes_last_open_ts = ctx.notes_last_open_ts or {}
  if not M.rate_ok(guid, now, ctx.notes_last_open_ts, opts.rate_limit_s) then
    return false, "rate_limited"
  end
  local qs = opts.qs or ""
  local status = M.status_url(base, guid, qs)
  local http_get = opts.http_get or M.default_http_get
  local missing = M.fetch_missing(status, http_get, opts.timeout_s or 3)
  if missing == nil then
    local reaper_api = ctx.reaper
    if reaper_api and reaper_api.ShowConsoleMsg and not ctx._notes_status_warned then
      ctx._notes_status_warned = true
      reaper_api.ShowConsoleMsg(
        "[PTT] notes status unreachable (" .. tostring(status) .. ") — auto-open skipped\n")
    end
    return false, "status_failed"
  end
  if missing <= 0 then
    return false, "complete"
  end
  local url = M.notes_url(base, guid, qs)
  local open_fn = opts.open_fn or M.open
  open_fn(url, ctx.reaper)
  ctx.notes_last_open_ts[guid] = now
  if ctx.reaper and ctx.reaper.ShowConsoleMsg then
    ctx.reaper.ShowConsoleMsg("[PTT] opening notes UI (" .. tostring(missing) .. " undocumented)\n")
  end
  return true, "opened"
end

function M.open_manual(ctx, opts)
  opts = opts or {}
  local cfg = (ctx and ctx.cfg) or {}
  local base = cfg.notes_ui_base_url or ""
  local reaper_api = (ctx and ctx.reaper) or reaper
  if base == "" then
    if reaper_api and reaper_api.ShowConsoleMsg then
      reaper_api.ShowConsoleMsg(
        "[PTT] notes_ui_base_url is empty — set it in ptt_config.json to open notes UI\n")
    end
    return false, "no_base"
  end
  local guid = (ctx and ctx.ident and ctx.ident.guid) or ""
  if guid == "" and reaper_api and reaper_api.GetProjExtState then
    local ret, stored = reaper_api.GetProjExtState(0, "ProjectTimeTracker", "project_guid")
    if ret == 1 and stored and stored ~= "" then
      guid = stored
    end
  end
  if guid == "" then
    if reaper_api and reaper_api.ShowConsoleMsg then
      reaper_api.ShowConsoleMsg("[PTT] no project GUID — save the project first\n")
    end
    return false, "no_guid"
  end
  local url = M.notes_url(base, guid, opts.qs or "")
  local open_fn = opts.open_fn or M.open
  open_fn(url, reaper_api)
  return true, "opened"
end
