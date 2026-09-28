local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("identity")
load_mod("sync_hook")
local fails = 0
local function expect(c, m)
  if not c then print("FAIL " .. m); fails = fails + 1 end
end

local snap = PTT.identity.snapshot({
  get_guid = function() return "{ABC-123}" end,
  get_project_path = function() return "/proj/dir" end,
  get_project_name = function() return "Show_v2.rpp" end,
  is_untitled = function() return false end,
})
expect(snap.guid == "ABC-123", "strip braces")
expect(snap.saved == true, "saved")

local d = PTT.identity.diff(
  { guid = "ABC-123", dir = "/old", name = "a.rpp", saved = true },
  { guid = "ABC-123", dir = "/new", name = "a.rpp", saved = true }
)
expect(d.path_changed == true, "path changed")
expect(d.guid_changed == false, "guid same")

d = PTT.identity.diff(
  { guid = "ABC-123", dir = "/p", name = "a.rpp", saved = true },
  { guid = "ABC-123", dir = "/p", name = "a_v2.rpp", saved = true }
)
expect(d.same_folder_rename == true, "version rename")

d = PTT.identity.diff(
  { guid = "", dir = "", name = "", saved = false },
  { guid = "ABC-123", dir = "/p", name = "a.rpp", saved = true }
)
expect(d.became_saved == true, "became saved")

expect(PTT.sync_hook.notify({ event = "heartbeat" }) == true, "sync noop")

return fails
