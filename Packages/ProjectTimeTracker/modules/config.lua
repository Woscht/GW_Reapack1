PTT = PTT or {}
PTT.config = PTT.config or {}
local M = PTT.config

-- Studio default: shared config on the PRODUKTION Cube (Windows UNC).
-- ExtState ptt_config_path still overrides when set. Linux mount listed
-- second so headless / office hosts find the same file without ExtState.
M.CANDIDATE_PATHS = {
  "\\\\192.168.203.33\\PRODUKTION\\01_Projekte\\_Temp\\ptt_e2e\\ptt_config.json",
  "/mnt/cube/01_Projekte/_Temp/ptt_e2e/ptt_config.json",
}

M.DEFAULTS = {
  mirror_interval_s = 300,
  mirror_enabled = true,
  central_timelogs_dir = "",
}

local function copy_defaults()
  return {
    mirror_interval_s = M.DEFAULTS.mirror_interval_s,
    mirror_enabled = M.DEFAULTS.mirror_enabled,
    central_timelogs_dir = M.DEFAULTS.central_timelogs_dir,
  }
end

local function normalize_dir(s)
  if type(s) ~= "string" or s == "" then
    return ""
  end
  s = s:match("^%s*(.-)%s*$") or s
  if s == "" then
    return ""
  end
  if s:match("^\\") then
    s = s:gsub("^\\+", "")
    s = s:gsub("\\+", "\\")
    return "\\" .. "\\" .. s
  end
  return s:gsub("\\+", "\\")
end

local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    else
      break
    end
  end
  return i
end

local parse_value

local function parse_string(s, i)
  if s:sub(i, i) ~= '"' then
    return nil, i, "expected string"
  end
  i = i + 1
  local parts = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(parts), i + 1
    end
    if c == "\\" then
      i = i + 1
      local e = s:sub(i, i)
      if e == '"' or e == "\\" or e == "/" then
        parts[#parts + 1] = e
      elseif e == "b" then
        parts[#parts + 1] = "\b"
      elseif e == "f" then
        parts[#parts + 1] = "\f"
      elseif e == "n" then
        parts[#parts + 1] = "\n"
      elseif e == "r" then
        parts[#parts + 1] = "\r"
      elseif e == "t" then
        parts[#parts + 1] = "\t"
      elseif e == "u" then
        local hex = s:sub(i + 1, i + 4)
        if not hex:match("^%x%x%x%x$") then
          return nil, i, "bad unicode escape"
        end
        parts[#parts + 1] = string.char(tonumber(hex, 16))
        i = i + 4
      else
        return nil, i, "bad escape"
      end
      i = i + 1
    else
      parts[#parts + 1] = c
      i = i + 1
    end
  end
  return nil, i, "unclosed string"
end

local function parse_number(s, i)
  local j = i
  if s:sub(j, j) == "-" then
    j = j + 1
  end
  if not s:sub(j, j):match("%d") then
    return nil, i, "expected number"
  end
  while j <= #s and s:sub(j, j):match("%d") do
    j = j + 1
  end
  if s:sub(j, j) == "." then
    j = j + 1
    while j <= #s and s:sub(j, j):match("%d") do
      j = j + 1
    end
  end
  local n = tonumber(s:sub(i, j - 1))
  if n == nil then
    return nil, i, "invalid number"
  end
  return n, j
end

local function parse_object(s, i)
  if s:sub(i, i) ~= "{" then
    return nil, i, "expected object"
  end
  i = skip_ws(s, i + 1)
  local obj = {}
  if s:sub(i, i) == "}" then
    return obj, i + 1
  end
  while true do
    i = skip_ws(s, i)
    local key, err
    key, i, err = parse_string(s, i)
    if key == nil then
      return nil, i, err or "expected key"
    end
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then
      return nil, i, "expected colon"
    end
    i = skip_ws(s, i + 1)
    local val
    val, i, err = parse_value(s, i)
    if err then
      return nil, i, err
    end
    obj[key] = val
    i = skip_ws(s, i)
    local sep = s:sub(i, i)
    if sep == "}" then
      return obj, i + 1
    end
    if sep ~= "," then
      return nil, i, "expected comma or end"
    end
    i = i + 1
  end
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return parse_string(s, i)
  end
  if c == "{" then
    return parse_object(s, i)
  end
  if s:sub(i, i + 3) == "true" then
    return true, i + 4
  end
  if s:sub(i, i + 4) == "false" then
    return false, i + 5
  end
  if s:sub(i, i + 3) == "null" then
    return nil, i + 4
  end
  if c == "-" or c:match("%d") then
    return parse_number(s, i)
  end
  return nil, i, "unexpected token"
end

function M.parse_json_object(text)
  if type(text) ~= "string" then
    return nil, "expected string"
  end
  local i = skip_ws(text, 1)
  if text:sub(i, i) ~= "{" then
    return nil, "expected object"
  end
  local obj, j, err = parse_object(text, i)
  if obj == nil then
    return nil, err or "parse error"
  end
  j = skip_ws(text, j)
  if j <= #text then
    return nil, "trailing data"
  end
  return obj
end

function M.load_from_text(text)
  local cfg = copy_defaults()
  if type(text) ~= "string" or text:match("^%s*$") then
    return cfg
  end
  local obj, err = M.parse_json_object(text)
  if not obj then
    return cfg
  end
  if obj.central_timelogs_dir ~= nil then
    cfg.central_timelogs_dir = normalize_dir(tostring(obj.central_timelogs_dir))
  end
  if type(obj.mirror_interval_s) == "number" then
    cfg.mirror_interval_s = obj.mirror_interval_s
  end
  if type(obj.mirror_enabled) == "boolean" then
    cfg.mirror_enabled = obj.mirror_enabled
  end
  return cfg
end

function M.load_from_paths(paths, io_open)
  io_open = io_open or io.open
  for _, path in ipairs(paths) do
    local f = io_open(path)
    if f then
      local body = f:read("*a")
      f:close()
      return M.load_from_text(body or ""), path
    end
  end
  return M.load_from_text(""), nil
end
