PTT = PTT or {}
PTT.report = {}
local M = PTT.report

local function parse_field(line, key)
  return line:match('"' .. key .. '"%s*:%s*"([^"]*)"')
      or line:match('"' .. key .. '"%s*:%s*([%d%.%-]+)')
end

function M.sum_log(log_text)
  local session_span_s = 0
  local rec_rolling_s = 0
  for line in (log_text or ""):gmatch("([^\n]+)") do
    local ev = parse_field(line, "event")
    local close = parse_field(line, "close_event")
    if ev == "session_end" or (ev == "crash_close" and close == "session_end") then
      session_span_s = session_span_s + (tonumber(parse_field(line, "span_accum")) or 0)
    end
    if ev == "rec_session_end" or (ev == "crash_close" and close == "rec_session_end") then
      rec_rolling_s = rec_rolling_s + (tonumber(parse_field(line, "rec_accum")) or 0)
    end
  end
  return { session_span_s = session_span_s, rec_rolling_s = rec_rolling_s }
end

function M.to_markdown(sum, meta)
  meta = meta or {}
  return table.concat({
    "# Project Time Report",
    "",
    string.format("- Project: %s", meta.project_name or ""),
    string.format("- GUID: %s", meta.project_guid or ""),
    string.format("- Session-Span (s): %.3f", sum.session_span_s or 0),
    string.format("- Rec-Rolling (s): %.3f", sum.rec_rolling_s or 0),
    "",
    "Office chooses which metric to bill.",
    "",
  }, "\n")
end

function M.to_csv(sum, meta)
  meta = meta or {}
  return table.concat({
    "project_name,project_guid,session_span_s,rec_rolling_s",
    string.format("%s,%s,%.3f,%.3f",
      meta.project_name or "",
      meta.project_guid or "",
      sum.session_span_s or 0,
      sum.rec_rolling_s or 0),
    "",
  }, "\n")
end
