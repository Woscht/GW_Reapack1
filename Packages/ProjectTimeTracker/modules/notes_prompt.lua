PTT = PTT or {}
PTT.notes_prompt = PTT.notes_prompt or {}
local M = PTT.notes_prompt

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function M.imgui_available(reaper_api)
  reaper_api = reaper_api or reaper
  if type(reaper_api) ~= "table" then
    return false
  end
  if type(reaper_api.ImGui_CreateContext) == "function" then
    return true
  end
  if type(reaper_api.ImGui_GetBuiltinPath) == "function" then
    return true
  end
  return false
end

function M.status_qs(ctx)
  ctx = ctx or {}
  local N = PTT.notes_ui
  local enc = N and N.query_encode or function(s) return tostring(s or "") end
  return "machine=" .. enc(ctx.machine_id or "") .. "&since=" .. enc(ctx.occupancy_since_iso or "")
end

function M.should_skip(ctx)
  if not ctx or not ctx.cfg then
    return "no_ctx"
  end
  if ctx.cfg.notes_auto_open == false then
    return "disabled"
  end
  if PTT.office_opt and PTT.office_opt.is_opted_out_ctx(ctx) then
    return "office_opt_out"
  end
  local base = ctx.cfg.notes_ui_base_url or ""
  if base == "" then
    return "no_base"
  end
  local ident = ctx.ident or {}
  if not ident.saved then
    return "unsaved"
  end
  if not ident.guid or ident.guid == "" then
    return "no_guid"
  end
  return nil
end

function M.can_save(texts_by_id)
  if type(texts_by_id) ~= "table" then
    return false
  end
  for _, v in pairs(texts_by_id) do
    if trim(v) ~= "" then
      return true
    end
  end
  return false
end

function M.append_note(path, rec, json_encode, io_open)
  json_encode = json_encode or (PTT.util and PTT.util.json_encode)
  io_open = io_open or io.open
  if not path or path == "" or type(json_encode) ~= "function" then
    return false
  end
  rec = rec or {}
  rec.schema = rec.schema or 1
  rec.deleted = not not rec.deleted
  local dir = tostring(path):match("^(.+)[/\\][^/\\]+$")
  if dir and dir ~= "" then
    os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
  end
  local f = io_open(path, "a+")
  if not f then
    return false
  end
  f:write("{" .. json_encode(rec) .. "}\n")
  f:close()
  return true
end

function M.skip(ctx)
  if ctx then
    ctx.notes_prompt = nil
  end
end

function M.save(ctx, texts_by_id, opts)
  opts = opts or {}
  local st = ctx and ctx.notes_prompt
  if not st then
    return false
  end
  texts_by_id = texts_by_id or {}
  local json_encode = (PTT.util and PTT.util.json_encode) or opts.json_encode
  local ts = (PTT.util and PTT.util.now_iso and PTT.util.now_iso(ctx.time_precise)) or ""
  local wrote = false
  for _, p in ipairs(st.prompt or {}) do
    local text = trim(texts_by_id[p.block_id])
    if text ~= "" then
      local rec = {
        schema = 1,
        ts = ts,
        project_guid = st.guid,
        block_id = p.block_id,
        text = text,
        author = st.machine or ctx.machine_id or "",
        deleted = false,
      }
      if M.append_note(st.notes_path, rec, json_encode, opts.io_open) then
        wrote = true
      end
    end
  end
  if wrote then
    local dest = nil
    if PTT.mirror and PTT.mirror.notes_dest_path and st.central and st.central ~= "" then
      dest = PTT.mirror.notes_dest_path(st.central, st.guid)
    end
    if opts.push_notes_fn then
      opts.push_notes_fn(st.notes_path, dest)
    elseif dest and st.notes_path and PTT.mirror and PTT.mirror.atomic_copy then
      PTT.mirror.atomic_copy(st.notes_path, dest, opts.fs or PTT.mirror.io_fs())
    end
  end
  ctx.notes_prompt = nil
  return wrote
end

function M.begin(ctx, opts)
  opts = opts or {}
  local skip = M.should_skip(ctx)
  if skip then
    return false, skip
  end
  if not ctx.occupancy_since_iso or ctx.occupancy_since_iso == "" then
    return false, "no_since"
  end
  local N = PTT.notes_ui
  local base = ctx.cfg.notes_ui_base_url
  local guid = ctx.ident.guid
  local qs = M.status_qs(ctx)
  local url = N.status_url(base, guid, qs)
  local http_get = opts.http_get or N.default_http_get
  local st = N.fetch_status(url, http_get, opts.timeout_s or 3)
  if not st then
    return false, "status_failed"
  end
  local prompt = st.prompt or {}
  if #prompt == 0 then
    return false, "empty_prompt"
  end
  local notes_path = nil
  if PTT.mirror and PTT.mirror.notes_src_path and ctx.writer then
    notes_path = PTT.mirror.notes_src_path(ctx.writer.path)
  end
  local notes_page_url = N.notes_url(base, guid, "")
  ctx.notes_prompt = {
    guid = guid,
    project_name = tostring((ctx.ident and ctx.ident.name) or ""),
    notes_path = notes_path,
    notes_page_url = notes_page_url,
    central = (ctx.cfg and ctx.cfg.central_timelogs_dir) or "",
    machine = ctx.machine_id or "",
    prompt = prompt,
    older_missing = st.older_missing or 0,
    texts = {},
  }
  return true, "opened"
end

function M.window_title(st)
  st = st or {}
  local name = trim(st.project_name)
  if name ~= "" then
    return "Projektdoku — " .. name
  end
  return "Projektdoku"
end

local MONTHS_DE = {
  "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni",
  "Juli", "Aug.", "Sep.", "Okt.", "Nov.", "Dez.",
}

local function dow_sun0(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then
    y = y - 1
  end
  return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[m] + d) % 7
end

local function last_sunday(year, month)
  local mdays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and ((year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0) then
    mdays[2] = 29
  end
  local d = mdays[month]
  while dow_sun0(year, month, d) ~= 0 do
    d = d - 1
  end
  return d
end

--- Europe/Berlin offset hours for a UTC wall time (CET=1, CEST=2).
function M.berlin_offset_hours(y, mo, d, h)
  local mar = last_sunday(y, 3)
  local oct = last_sunday(y, 10)
  local after_start = (mo > 3) or (mo == 3 and (d > mar or (d == mar and h >= 1)))
  local before_end = (mo < 10) or (mo == 10 and (d < oct or (d == oct and h < 1)))
  if after_start and before_end then
    return 2
  end
  return 1
end

function M.parse_iso_utc(iso)
  local y, mo, d, h, mi = tostring(iso or ""):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not y then
    return nil
  end
  return {
    y = tonumber(y),
    mo = tonumber(mo),
    d = tonumber(d),
    h = tonumber(h),
    mi = tonumber(mi),
  }
end

local function add_hours(parts, add)
  local h = parts.h + add
  local d = parts.d
  local mo = parts.mo
  local y = parts.y
  local mdays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then
    mdays[2] = 29
  end
  while h >= 24 do
    h = h - 24
    d = d + 1
    if d > mdays[mo] then
      d = 1
      mo = mo + 1
      if mo > 12 then
        mo = 1
        y = y + 1
        mdays[2] = ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 29 or 28
      end
    end
  end
  while h < 0 do
    h = h + 24
    d = d - 1
    if d < 1 then
      mo = mo - 1
      if mo < 1 then
        mo = 12
        y = y - 1
        mdays[2] = ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 29 or 28
      end
      d = mdays[mo]
    end
  end
  return { y = y, mo = mo, d = d, h = h, mi = parts.mi }
end

--- Friendly Berlin local parts from UTC ISO, or nil.
function M.iso_to_berlin(iso)
  local utc = M.parse_iso_utc(iso)
  if not utc then
    return nil
  end
  local off = M.berlin_offset_hours(utc.y, utc.mo, utc.d, utc.h)
  return add_hours(utc, off)
end

function M.format_berlin_date(parts)
  if not parts then
    return ""
  end
  return string.format("%d. %s %04d", parts.d, MONTHS_DE[parts.mo] or "?", parts.y)
end

function M.format_berlin_clock(parts)
  if not parts then
    return ""
  end
  return string.format("%02d:%02d", parts.h, parts.mi)
end

--- e.g. "8. Okt. 2026  ·  12:00 – 13:30"
function M.format_clock_range(start_iso, end_iso)
  local a = M.iso_to_berlin(start_iso)
  local b = M.iso_to_berlin(end_iso)
  if not a or not b then
    local s = trim(start_iso)
    local e = trim(end_iso)
    if s ~= "" and e ~= "" then
      return s .. " – " .. e
    end
    return s ~= "" and s or e
  end
  local da = M.format_berlin_date(a)
  local db = M.format_berlin_date(b)
  local ca = M.format_berlin_clock(a)
  local cb = M.format_berlin_clock(b)
  if da == db then
    return da .. "  ·  " .. ca .. " – " .. cb
  end
  return da .. " " .. ca .. "  –  " .. db .. " " .. cb
end

function M.kind_label(kind)
  if kind == "recording" then
    return "Aufnahme"
  end
  return "Schnitt"
end

function M.run_fallback(ctx, opts)
  opts = opts or {}
  local st = ctx and ctx.notes_prompt
  if not st then
    return "skipped"
  end
  local user_inputs = opts.user_inputs
  if not user_inputs then
    local r = ctx.reaper
    user_inputs = function(title, caption, default)
      if not r or type(r.GetUserInputs) ~= "function" then
        return false, ""
      end
      local ok, csv = r.GetUserInputs(title, 1, caption, default or "")
      return ok, csv
    end
  end
  local title = M.window_title(st)
  local texts = {}
  local saved_any = false
  for _, p in ipairs(st.prompt or {}) do
    local kind = M.kind_label(p.kind)
    local when = M.format_clock_range(p.start, p["end"])
    local cap = kind .. (when ~= "" and (" — " .. when) or "") .. ":"
    if (st.older_missing or 0) > 0 then
      cap = tostring(st.older_missing) .. " ältere Blöcke ohne Text — im Office nachtragen.," .. cap
    end
    if st.notes_page_url and st.notes_page_url ~= "" then
      cap = "HTML: " .. tostring(st.notes_page_url) .. "," .. cap
    end
    local ok, text = user_inputs(title, cap, "")
    if not ok then
      if saved_any then
        M.save(ctx, texts, opts)
        return "saved"
      end
      M.skip(ctx)
      return "skipped"
    end
    texts[p.block_id] = text or ""
    if trim(text) ~= "" then
      saved_any = true
    end
  end
  if M.can_save(texts) then
    M.save(ctx, texts, opts)
    return "saved"
  end
  M.skip(ctx)
  return "skipped"
end

M.WINDOW_W = 860
M.WINDOW_H = 600
M.FIELD_W = 800
M.FIELD_H = 200

-- Soft light organic palette (0xRRGGBBAA)
local COL = {
  window_bg = 0xF4F7FAFF,
  child_bg = 0xFFFFFFFF,
  text = 0x1E293BFF,
  muted = 0x64748BFF,
  frame_bg = 0xEEF3F7FF,
  frame_bg_active = 0xE2EAF2FF,
  border = 0xD8E0E8FF,
  button = 0x0F766EFF,
  button_hov = 0x0D9488FF,
  button_act = 0x115E59FF,
  button_text = 0xFFFFFFFF,
  secondary = 0xE8EEF3FF,
  secondary_hov = 0xD9E2ECFF,
  secondary_text = 0x334155FF,
  accent_rec = 0xB45309FF,
  accent_edit = 0x0369A1FF,
}

local function enum_val(r, name)
  local v = r["ImGui_" .. name]
  if type(v) == "function" then
    return v()
  end
  if type(v) == "number" then
    return v
  end
  return nil
end

local function push_style(r, ic)
  local nvar, ncol = 0, 0
  local function svar(name, a, b)
    local idx = enum_val(r, name)
    if not idx or not r.ImGui_PushStyleVar then
      return
    end
    if b ~= nil then
      r.ImGui_PushStyleVar(ic, idx, a, b)
    else
      r.ImGui_PushStyleVar(ic, idx, a)
    end
    nvar = nvar + 1
  end
  local function scol(name, col)
    local idx = enum_val(r, name)
    if not idx or not r.ImGui_PushStyleColor then
      return
    end
    r.ImGui_PushStyleColor(ic, idx, col)
    ncol = ncol + 1
  end
  svar("StyleVar_WindowRounding", 14)
  svar("StyleVar_ChildRounding", 14)
  svar("StyleVar_FrameRounding", 10)
  svar("StyleVar_GrabRounding", 8)
  svar("StyleVar_WindowPadding", 28, 24)
  svar("StyleVar_FramePadding", 14, 11)
  svar("StyleVar_ItemSpacing", 14, 12)
  svar("StyleVar_ItemInnerSpacing", 10, 8)
  svar("StyleVar_WindowBorderSize", 0)
  svar("StyleVar_ChildBorderSize", 1)
  svar("StyleVar_FrameBorderSize", 0)
  scol("Col_WindowBg", COL.window_bg)
  scol("Col_ChildBg", COL.child_bg)
  scol("Col_Text", COL.text)
  scol("Col_TextDisabled", COL.muted)
  scol("Col_Border", COL.border)
  scol("Col_Separator", COL.border)
  scol("Col_FrameBg", COL.frame_bg)
  scol("Col_FrameBgHovered", COL.frame_bg_active)
  scol("Col_FrameBgActive", COL.frame_bg_active)
  scol("Col_Button", COL.button)
  scol("Col_ButtonHovered", COL.button_hov)
  scol("Col_ButtonActive", COL.button_act)
  scol("Col_ScrollbarBg", 0x00000000)
  scol("Col_ScrollbarGrab", 0xCBD5E1FF)
  return nvar, ncol
end

local function pop_style(r, ic, nvar, ncol)
  if nvar > 0 and r.ImGui_PopStyleVar then
    r.ImGui_PopStyleVar(ic, nvar)
  end
  if ncol > 0 and r.ImGui_PopStyleColor then
    r.ImGui_PopStyleColor(ic, ncol)
  end
end

local function text_muted(r, ic, s)
  if r.ImGui_TextColored then
    r.ImGui_TextColored(ic, COL.muted, s)
  else
    r.ImGui_Text(ic, s)
  end
end

local function text_scale(r, ic, scale, draw_fn)
  if r.ImGui_SetWindowFontScale then
    r.ImGui_SetWindowFontScale(ic, scale)
    draw_fn()
    r.ImGui_SetWindowFontScale(ic, 1.0)
  else
    draw_fn()
  end
end

local function spaced(r, ic, h)
  if r.ImGui_Dummy then
    r.ImGui_Dummy(ic, 1, h or 8)
  end
end

function M.draw_imgui(ctx, opts)
  opts = opts or {}
  local r = ctx.reaper
  local st = ctx.notes_prompt
  if not st or not r then
    return
  end
  local ok_ctx, ic = pcall(function()
    if st.imgui then
      return st.imgui
    end
    return r.ImGui_CreateContext("PTT-Projektdoku")
  end)
  if not ok_ctx or not ic then
    M.run_fallback(ctx, opts)
    return
  end
  st.imgui = ic
  local ok_ui, err = pcall(function()
    local title = M.window_title(st)
    if r.ImGui_SetNextWindowSize then
      local cond = 1
      if type(r.ImGui_Cond_Always) == "function" then
        cond = r.ImGui_Cond_Always()
      elseif type(r.ImGui_Cond_Always) == "number" then
        cond = r.ImGui_Cond_Always
      end
      r.ImGui_SetNextWindowSize(ic, M.WINDOW_W, M.WINDOW_H, cond)
    end
    local nvar, ncol = push_style(r, ic)
    local visible, open = r.ImGui_Begin(ic, title, true)
    if visible then
      local name = trim(st.project_name)
      text_scale(r, ic, 1.55, function()
        r.ImGui_Text(ic, name ~= "" and name or "Projektdoku")
      end)
      text_muted(r, ic, "Kurz festhalten, was in diesem Block passiert ist.")
      spaced(r, ic, 10)

      local child_flags = enum_val(r, "ChildFlags_None") or 0
      local borders = enum_val(r, "ChildFlags_Borders")
      if borders then
        child_flags = child_flags | borders
      end
      local auto_y = enum_val(r, "ChildFlags_AutoResizeY")
      if auto_y then
        child_flags = child_flags | auto_y
      end

      for _, p in ipairs(st.prompt or {}) do
        local opened = true
        if r.ImGui_BeginChild then
          opened = r.ImGui_BeginChild(ic, "##card_" .. tostring(p.block_id), 0, 0, child_flags)
        end
        if opened then
          local kind = M.kind_label(p.kind)
          local kind_col = (p.kind == "recording") and COL.accent_rec or COL.accent_edit
          if r.ImGui_TextColored then
            r.ImGui_TextColored(ic, kind_col, kind)
          else
            r.ImGui_Text(ic, kind)
          end
          spaced(r, ic, 4)
          text_scale(r, ic, 1.2, function()
            r.ImGui_Text(ic, M.format_clock_range(p.start, p["end"]))
          end)
          spaced(r, ic, 8)
          text_muted(r, ic, "Deine Notiz")
          st.texts[p.block_id] = st.texts[p.block_id] or ""
          local changed, text = r.ImGui_InputTextMultiline(
            ic, "##" .. p.block_id, st.texts[p.block_id], M.FIELD_W, M.FIELD_H)
          if changed then
            st.texts[p.block_id] = text
          end
          if r.ImGui_EndChild then
            r.ImGui_EndChild(ic)
          end
        end
        spaced(r, ic, 6)
      end

      if (st.older_missing or 0) > 0 then
        text_muted(
          r, ic,
          tostring(st.older_missing)
            .. " ältere Blöcke ohne Text — im Office nachtragen.")
      end
      if st.notes_page_url and st.notes_page_url ~= "" then
        if r.ImGui_TextLinkOpenURL then
          r.ImGui_TextLinkOpenURL(ic, "Dokumentation im Browser öffnen", st.notes_page_url)
        elseif r.ImGui_Button(ic, "Dokumentation im Browser") then
          if PTT.notes_ui and PTT.notes_ui.open then
            PTT.notes_ui.open(st.notes_page_url, r)
          end
        else
          text_muted(r, ic, st.notes_page_url)
        end
      end

      spaced(r, ic, 12)
      local can = M.can_save(st.texts)
      if r.ImGui_BeginDisabled and not can then
        r.ImGui_BeginDisabled(ic)
      end
      local save_label = "  Speichern  "
      if r.ImGui_Button(ic, save_label) and can then
        M.save(ctx, st.texts, opts)
      end
      if r.ImGui_EndDisabled and not can then
        r.ImGui_EndDisabled(ic)
      end
      if r.ImGui_SameLine then
        r.ImGui_SameLine(ic, nil, 16)
      end
      -- Softer secondary action
      local sc = 0
      if r.ImGui_PushStyleColor then
        local b = enum_val(r, "Col_Button")
        local bh = enum_val(r, "Col_ButtonHovered")
        local ba = enum_val(r, "Col_ButtonActive")
        local t = enum_val(r, "Col_Text")
        if b then r.ImGui_PushStyleColor(ic, b, COL.secondary); sc = sc + 1 end
        if bh then r.ImGui_PushStyleColor(ic, bh, COL.secondary_hov); sc = sc + 1 end
        if ba then r.ImGui_PushStyleColor(ic, ba, COL.secondary_hov); sc = sc + 1 end
        if t then r.ImGui_PushStyleColor(ic, t, COL.secondary_text); sc = sc + 1 end
      end
      if r.ImGui_Button(ic, "  Ohne Projektdoku  ") then
        M.skip(ctx)
      end
      if sc > 0 and r.ImGui_PopStyleColor then
        r.ImGui_PopStyleColor(ic, sc)
      end
    end
    r.ImGui_End(ic)
    pop_style(r, ic, nvar, ncol)
    if open == false then
      M.skip(ctx)
    end
  end)
  if not ok_ui then
    if ctx.reaper and ctx.reaper.ShowConsoleMsg then
      ctx.reaper.ShowConsoleMsg("[PTT] ImGui notes dialog failed: " .. tostring(err) .. "\n")
    end
    M.run_fallback(ctx, opts)
  end
end

function M.tick(ctx, opts)
  opts = opts or {}
  local st = ctx and ctx.notes_prompt
  if not st then
    return "closed"
  end
  if opts.draw_fn then
    local action, texts = opts.draw_fn(st)
    if action == "save" then
      if M.can_save(texts) then
        M.save(ctx, texts, opts)
      end
      return ctx.notes_prompt and "open" or "closed"
    elseif action == "skip" then
      M.skip(ctx)
      return "closed"
    end
    return "open"
  end
  local avail = opts.imgui_available or function()
    return M.imgui_available(ctx.reaper)
  end
  if not avail() then
    M.run_fallback(ctx, opts)
    return "closed"
  end
  M.draw_imgui(ctx, opts)
  return ctx.notes_prompt and "open" or "closed"
end
