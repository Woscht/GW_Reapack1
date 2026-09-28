local function load_mod(name)
  local dir = debug.getinfo(1, "S").source:match("^@(.+)/") .. "/../modules/"
  local env = { PTT = _G.PTT or {} }
  setmetatable(env, { __index = _G })
  assert(loadfile(dir .. name .. ".lua", "t", env))()
  _G.PTT = env.PTT
end

_G.PTT = {}
load_mod("activity")
local A = PTT.activity
local fails = 0
local function expect(c, m)
  if not c then
    print("FAIL " .. m)
    fails = fails + 1
  end
end

local prev = {
  edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
}

local r = A.classify(prev, {
  play_state = 1, edit_cursor = 0, play_cursor = 1.0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == true and r.reason == "play", "play active")

r = A.classify(prev, {
  play_state = 4, edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == true and r.reason == "record", "record active")

r = A.classify(prev, {
  play_state = 2, edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == false, "pause inactive")

r = A.classify(prev, {
  play_state = 0, edit_cursor = 2.5, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == true and r.reason == "interaction", "cursor move")

r = A.classify(prev, {
  play_state = 0, edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "b"
})
expect(r.active == true, "selection change")

r = A.classify(prev, {
  play_state = 0, edit_cursor = 0, play_cursor = 0, is_dirty = true, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == true, "dirty")

r = A.classify(prev, {
  play_state = 0, edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 3, sel_fingerprint = "a"
})
expect(r.active == true, "undo")

-- play+pause bits (state 3): play wins
r = A.classify(prev, {
  play_state = 3, edit_cursor = 0, play_cursor = 0, is_dirty = false, undo_count = 0, sel_fingerprint = "a"
})
expect(r.active == true and r.reason == "play", "play+pause bit still play")

return fails
