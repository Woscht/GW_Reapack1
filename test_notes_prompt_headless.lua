-- test_notes_prompt_headless.lua
-- Headless REAPER: occupancy prompt begin/save, captured-guid notes copy, ImGui present.

local STATUS = os.getenv("REAPER_HEADLESS_STATUS")
  or "/tmp/ptt_notes_prompt_headless_status.txt"
local PKG = os.getenv("PTT_PKG_ROOT")
  or "/home/doktorlinux/reaper-services/Zeiterfassung/ProjectTimeTracker/Packages/ProjectTimeTracker"
local OFFICE = os.getenv("NOTES_UI_BASE") or "http://127.0.0.1:3001"

local function write_status(line)
  local f = io.open(STATUS, "w")
  if f then f:write(line .. "\n"); f:close() end
  reaper.ShowConsoleMsg(line .. "\n")
end

local function fail(msg)
  write_status("ERROR: " .. msg)
end

local function ok(msg)
  write_status("OK: " .. msg)
end

local function load_modules()
  PTT = { _script_root = PKG .. "/", VERSION = "2.2.0" }
  local mods = {
    "util", "activity", "session_wall", "session_rec", "writer",
    "crash", "report", "path_migrate", "untitled", "identity",
    "sync_hook", "config", "office_opt", "mirror", "notes_ui",
    "notes_prompt", "bootstrap",
  }
  for _, m in ipairs(mods) do
    local path = PKG .. "/modules/" .. m .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("load " .. m .. ": " .. tostring(err)) end
    chunk()
  end
end

local function main()
  local loaded, err = pcall(load_modules)
  if not loaded then
    fail("module load: " .. tostring(err))
    return
  end
  if not (PTT.notes_prompt and PTT.bootstrap and PTT.notes_ui) then
    fail("notes_prompt/bootstrap missing")
    return
  end

  local ctx = {
    time_precise = reaper.time_precise and function() return reaper.time_precise() end or nil,
  }
  PTT.bootstrap.mark_occupancy(ctx)
  if type(ctx.occupancy_since_iso) ~= "string" or not ctx.occupancy_since_iso:find("T") then
    fail("occupancy_since_iso")
    return
  end

  local tmp = "/tmp/ptt_prompt_headless_" .. tostring(os.time())
  os.execute('mkdir -p "' .. tmp .. '/local" "' .. tmp .. '/central"')
  local guid = "HEADLESS-PROMPT-001"
  local notes_path = tmp .. "/local/" .. guid .. ".notes.jsonl"
  local central = tmp .. "/central"
  local body = '{"blocks":2,"missing":2,"older_missing":1,"prompt":[{"block_id":"edit:wall_a:2026-10-06T10:00:00","kind":"edit","start":"2026-10-06T10:00:00.000Z","end":"2026-10-06T11:00:00.000Z","duration_s":3600,"machine":"Mac.local"}]}'

  local pctx = {
    cfg = {
      notes_ui_base_url = OFFICE,
      notes_auto_open = true,
      central_timelogs_dir = central,
    },
    ident = { guid = guid, saved = true },
    occupancy_since_iso = ctx.occupancy_since_iso,
    machine_id = "Mac.local",
    writer = { path = tmp .. "/local/" .. guid .. ".timelog.jsonl" },
    reaper = reaper,
  }
  local did, reason = PTT.notes_prompt.begin(pctx, {
    http_get = function() return body end,
  })
  if not did or reason ~= "opened" then
    fail("begin: " .. tostring(reason))
    return
  end
  if pctx.notes_prompt.guid ~= guid then
    fail("prompt guid")
    return
  end
  pctx.notes_prompt.notes_path = notes_path
  local ticked = PTT.notes_prompt.tick(pctx, {
    imgui_available = function() return true end,
    draw_fn = function(state)
      return "save", { [state.prompt[1].block_id] = "Headless Kommentar" }
    end,
  })
  if ticked ~= "closed" then
    fail("tick not closed: " .. tostring(ticked))
    return
  end
  local nf = io.open(notes_path, "r")
  local nbody = nf and nf:read("*a") or ""
  if nf then nf:close() end
  if not nbody:find("Headless Kommentar", 1, true) then
    fail("local notes missing text: " .. nbody)
    return
  end
  if not nbody:find("edit:wall_a:2026-10-06T10:00:00", 1, true) then
    fail("local notes missing block_id")
    return
  end
  local dest = central .. "/" .. guid .. ".notes.jsonl"
  local cf = io.open(dest, "r")
  local cbody = cf and cf:read("*a") or ""
  if cf then cf:close() end
  if cbody ~= nbody then
    fail("central notes mismatch local (dest=" .. dest .. " central=" .. tostring(cbody) .. ")")
    return
  end

  local imgui_fn = type(reaper.ImGui_CreateContext)
  local imgui_path = type(reaper.ImGui_GetBuiltinPath)
  local imgui_ok = (imgui_fn == "function") or (imgui_path == "function")

  local live = PTT.notes_ui.default_http_get(
    OFFICE .. "/projects/GUID-BLOCKS-001/notes/status?machine=x&since=2026-10-06T00:00:00.000Z", 3)
  if not live or not live:find('"prompt"', 1, true) then
    fail("live office status missing prompt key: " .. tostring(live))
    return
  end
  local parsed = select(1, PTT.config.parse_json_object(live))
  if type(parsed) ~= "table" or type(parsed.prompt) ~= "table" then
    fail("live status not parseable")
    return
  end

  if not imgui_ok then
    fail("ReaImGui not loaded (ImGui_CreateContext=" .. imgui_fn .. " GetBuiltinPath=" .. imgui_path .. ")")
    return
  end

  ok(string.format(
    "notes_prompt save+mirror + live prompt JSON + ImGui (%s/%s) office=%s",
    imgui_fn, imgui_path, live:gsub("%s+", " "):sub(1, 180)))
end

local ran, err = pcall(main)
if not ran then
  fail("pcall: " .. tostring(err))
end

reaper.defer(function()
  reaper.Main_OnCommand(40004, 0)
end)
