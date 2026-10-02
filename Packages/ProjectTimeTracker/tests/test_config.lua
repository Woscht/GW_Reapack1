local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("config")
local C = PTT.config
local D = C.DEFAULTS
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

expect(D.mirror_interval_s == 300, "default interval")
expect(D.mirror_enabled == true, "default mirror_enabled")
expect(D.central_timelogs_dir == "", "default central dir")
expect(#C.CANDIDATE_PATHS >= 1, "studio candidate paths shipped")
expect(
  C.CANDIDATE_PATHS[1] == "\\\\192.168.203.33\\PRODUKTION\\01_Projekte\\_Temp\\ptt_e2e\\ptt_config.json",
  "primary UNC candidate"
)

local empty_cfg = C.load_from_text("")
expect(empty_cfg.mirror_interval_s == 300, "empty text interval default")
expect(empty_cfg.mirror_enabled == true, "empty text mirror default")
expect(empty_cfg.central_timelogs_dir == "", "empty text dir default")

local json = '{"central_timelogs_dir":"\\\\\\\\server\\\\share\\\\Zeiterfassung\\\\timelogs","mirror_interval_s":120,"mirror_enabled":false}'
local parsed, perr = C.parse_json_object(json)
expect(perr == nil and parsed ~= nil, "parse ok")
if parsed then
  expect(parsed.central_timelogs_dir == "\\\\server\\share\\Zeiterfassung\\timelogs", "parsed unc dir")
  expect(parsed.mirror_interval_s == 120, "parsed interval")
  expect(parsed.mirror_enabled == false, "parsed mirror flag")
end

local cfg = C.load_from_text(json)
expect(cfg.central_timelogs_dir == "\\\\server\\share\\Zeiterfassung\\timelogs", "load merge dir normalized")
expect(cfg.mirror_interval_s == 120, "load merge interval")
expect(cfg.mirror_enabled == false, "load merge mirror")

local bad, berr = C.parse_json_object("{not json")
expect(bad == nil and berr ~= nil, "invalid json parse fails")
local safe = C.load_from_text("{not json")
expect(safe.mirror_interval_s == 300 and safe.mirror_enabled == true, "invalid json load defaults")

local files = {
  ["/missing/ptt_config.json"] = nil,
  ["/ok/ptt_config.json"] = '{"mirror_interval_s":60}',
  ["/later/ptt_config.json"] = '{"mirror_interval_s":10}',
}
local fake_open = function(path)
  local text = files[path]
  if text == nil then return nil end
  return {
    read = function(_, n)
      if n == "*a" then return text end
      return nil
    end,
    close = function() end,
  }
end
local pcfg, src = C.load_from_paths({ "/missing/ptt_config.json", "/ok/ptt_config.json", "/later/ptt_config.json" }, fake_open)
expect(src == "/ok/ptt_config.json", "first readable path")
expect(pcfg.mirror_interval_s == 60, "path load merge")
expect(pcfg.mirror_enabled == true, "path load default bool")

local none_cfg, none_src = C.load_from_paths({ "/nope.json" }, fake_open)
expect(none_src == nil, "no file source nil")
expect(none_cfg.mirror_interval_s == 300, "no file defaults")

return fails
