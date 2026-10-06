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
    local kind = (p.kind == "recording") and "Recording" or "Edit"
    local cap = kind .. ":"
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

M.WINDOW_W = 780
M.WINDOW_H = 520
M.FIELD_W = 740
M.FIELD_H = 180

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
    local visible, open = r.ImGui_Begin(ic, title, true)
    if visible then
      local name = trim(st.project_name)
      if name ~= "" then
        if r.ImGui_SetWindowFontScale then
          r.ImGui_SetWindowFontScale(ic, 1.35)
          r.ImGui_Text(ic, name)
          r.ImGui_SetWindowFontScale(ic, 1.0)
        else
          r.ImGui_Text(ic, "Projekt: " .. name)
        end
        if r.ImGui_Separator then
          r.ImGui_Separator(ic)
        end
      end
      for _, p in ipairs(st.prompt or {}) do
        local kind = (p.kind == "recording") and "Recording" or "Edit"
        r.ImGui_Text(ic, kind .. "  " .. tostring(p.start or "") .. " – " .. tostring(p["end"] or ""))
        st.texts[p.block_id] = st.texts[p.block_id] or ""
        local changed, text = r.ImGui_InputTextMultiline(
          ic, "##" .. p.block_id, st.texts[p.block_id], M.FIELD_W, M.FIELD_H)
        if changed then
          st.texts[p.block_id] = text
        end
      end
      if (st.older_missing or 0) > 0 then
        r.ImGui_Text(
          ic,
          tostring(st.older_missing) .. " ältere Blöcke ohne Text — im Office nachtragen.")
      end
      if st.notes_page_url and st.notes_page_url ~= "" then
        r.ImGui_Text(ic, "HTML-Dokumentation:")
        if r.ImGui_TextLinkOpenURL then
          r.ImGui_TextLinkOpenURL(ic, st.notes_page_url, st.notes_page_url)
        elseif r.ImGui_Button(ic, "Im Browser öffnen") then
          if PTT.notes_ui and PTT.notes_ui.open then
            PTT.notes_ui.open(st.notes_page_url, r)
          end
        else
          r.ImGui_Text(ic, st.notes_page_url)
        end
      end
      local can = M.can_save(st.texts)
      if r.ImGui_BeginDisabled and not can then
        r.ImGui_BeginDisabled(ic)
      end
      if r.ImGui_Button(ic, "Speichern") and can then
        M.save(ctx, st.texts, opts)
      end
      if r.ImGui_EndDisabled and not can then
        r.ImGui_EndDisabled(ic)
      end
      if r.ImGui_SameLine then
        r.ImGui_SameLine(ic)
      end
      if r.ImGui_Button(ic, "Ohne Projektdoku") then
        M.skip(ctx)
      end
    end
    r.ImGui_End(ic)
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
