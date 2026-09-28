local fails = 0
local function expect(cond, msg)
  if not cond then
    print("FAIL: " .. msg)
    fails = fails + 1
  end
end
expect(1 + 1 == 2, "math works")
return fails
