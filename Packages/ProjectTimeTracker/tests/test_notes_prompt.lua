local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("util")
load_mod("config")
load_mod("office_opt")
load_mod("mirror")
load_mod("notes_ui")
load_mod("notes_prompt")
load_mod("bootstrap")
local N = PTT.notes_prompt

local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(N.imgui_available({}) == false, "imgui missing")
expect(N.can_save({ e1 = "" }) == false, "can_save empty")
expect(N.can_save({ e1 = " hi " }) == true, "can_save trim")

local base_cfg = {
  notes_ui_base_url = "http://office:3001",
  notes_auto_open = true,
  central_timelogs_dir = "/tmp/ptt_prompt_central",
}
local function ctx_ok(extra)
  extra = extra or {}
  local c = {
    cfg = extra.cfg or base_cfg,
    ident = extra.ident or { guid = "G1", saved = true, name = "Demo.RPP" },
    occupancy_since_iso = extra.since or "2026-10-06T08:00:00.000Z",
    machine_id = extra.machine or "Mac.local",
    writer = extra.writer or { path = "/tmp/ptt_prompt_local/G1.timelog.jsonl" },
    now = function() return 1 end,
  }
  for k, v in pairs(extra) do
    if k ~= "cfg" and k ~= "ident" and k ~= "since" and k ~= "machine" and k ~= "writer" then
      c[k] = v
    end
  end
  return c
end

expect(N.should_skip(ctx_ok({ ident = { guid = "G1", saved = false } })) == "unsaved", "skip unsaved")
expect(N.should_skip(ctx_ok({ cfg = { notes_ui_base_url = "", notes_auto_open = true } })) == "no_base", "skip no_base")
expect(N.should_skip(ctx_ok({ cfg = { notes_ui_base_url = "http://x", notes_auto_open = false } })) == "disabled", "skip disabled")
expect(N.should_skip(ctx_ok({ office_opted_out = true })) == "office_opt_out", "skip opt out")
expect(N.should_skip(ctx_ok()) == nil, "no skip")

local body = '{"blocks":3,"missing":2,"older_missing":1,"prompt":[{"block_id":"e1","kind":"edit","start":"s","end":"e","duration_s":10,"machine":"Mac.local"}]}'
local ctx = ctx_ok()
local ok, reason = N.begin(ctx, { http_get = function() return body end })
expect(ok == true and reason == "opened", "begin opened")
expect(ctx.notes_prompt and ctx.notes_prompt.guid == "G1", "captured guid")
expect(ctx.notes_prompt.project_name == "Demo.RPP", "captured project name")
expect(ctx.notes_prompt.notes_path:find("G1.notes.jsonl", 1, true) ~= nil, "notes path")
expect(N.window_title({ project_name = "Folge18.RPP" }) == "Projektdoku — Folge18.RPP", "title with name")
expect(N.window_title({}) == "Projektdoku", "title without name")

ok, reason = N.begin(ctx_ok({ since = "" }), { http_get = function() return body end })
expect(ok == false and reason == "no_since", "no_since")

ok, reason = N.begin(ctx_ok(), { http_get = function() return '{"blocks":1,"missing":0,"prompt":[],"older_missing":0}' end })
expect(ok == false and reason == "empty_prompt", "empty prompt")

ok, reason = N.begin(ctx_ok(), { http_get = function() return nil end })
expect(ok == false and reason == "status_failed", "status fail")

local tmp = os.tmpname()
os.remove(tmp)
expect(N.append_note(tmp, {
  schema = 1, ts = "t", project_guid = "G1", block_id = "e1", text = "hi", author = "M", deleted = false,
}, PTT.util.json_encode), "append_note")
local f = io.open(tmp, "r")
local line = f and f:read("*a") or ""
if f then f:close() end
expect(line:find('"block_id":"e1"', 1, true) ~= nil, "append has id")
expect(line:find('"text":"hi"', 1, true) ~= nil, "append has text")
os.remove(tmp)

local pushed = {}
local save_ctx = ctx_ok()
N.begin(save_ctx, {
  http_get = function()
    return '{"blocks":2,"missing":2,"older_missing":0,"prompt":['
      .. '{"block_id":"e1","kind":"edit","start":"s","end":"e","duration_s":1,"machine":"M"},'
      .. '{"block_id":"r1","kind":"recording","start":"s","end":"e","duration_s":1,"machine":"M"}]}'
  end,
})
local notes_tmp = os.tmpname()
os.remove(notes_tmp)
save_ctx.notes_prompt.notes_path = notes_tmp
N.save(save_ctx, { e1 = "Kommentar", r1 = "   " }, {
  push_notes_fn = function(src, dest)
    pushed[#pushed + 1] = { src = src, dest = dest }
  end,
})
local nf = io.open(notes_tmp, "r")
local nbody = nf and nf:read("*a") or ""
if nf then nf:close() end
os.remove(notes_tmp)
expect(nbody:find("e1", 1, true) ~= nil and not nbody:find("r1", 1, true), "save only filled")
expect(#pushed == 1 and pushed[1].src == notes_tmp, "push captured path")
expect(save_ctx.notes_prompt == nil, "save clears state")

local skip_ctx = ctx_ok()
N.begin(skip_ctx, { http_get = function() return body end })
N.skip(skip_ctx)
expect(skip_ctx.notes_prompt == nil, "skip clears")

local fb = ctx_ok()
N.begin(fb, { http_get = function() return body end })
fb.notes_prompt.notes_path = os.tmpname()
os.remove(fb.notes_prompt.notes_path)
local fb_calls = 0
local result = N.run_fallback(fb, {
  user_inputs = function()
    fb_calls = fb_calls + 1
    return false, ""
  end,
  push_notes_fn = function() error("no push on skip") end,
})
expect(result == "skipped" and fb_calls == 1, "fallback cancel skip")

local imgui_ctx = ctx_ok()
N.begin(imgui_ctx, { http_get = function() return body end })
local ticked = N.tick(imgui_ctx, {
  imgui_available = function() return true end,
  draw_fn = function(state)
    return "save", { [state.prompt[1].block_id] = "Kommentar" }
  end,
  push_notes_fn = function() end,
})
expect(ticked == "closed" and imgui_ctx.notes_prompt == nil, "tick save via draw_fn")

local skip_tick = ctx_ok()
N.begin(skip_tick, { http_get = function() return body end })
N.tick(skip_tick, {
  imgui_available = function() return true end,
  draw_fn = function() return "skip" end,
})
expect(skip_tick.notes_prompt == nil, "tick skip")

if PTT.bootstrap and PTT.bootstrap.mark_occupancy then
  local bctx = { time_precise = function() return 1 end }
  PTT.bootstrap.mark_occupancy(bctx)
  expect(type(bctx.occupancy_since_iso) == "string" and bctx.occupancy_since_iso:find("T") ~= nil, "occupancy iso")
end

return fails
