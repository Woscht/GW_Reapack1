PTT = PTT or {}
PTT.writer = {}
local M = PTT.writer

function M.new(opts)
  opts = opts or {}
  local w = {
    path = opts.path,
    json_encode = opts.json_encode or (PTT.util and PTT.util.json_encode),
    io_open = opts.io_open or io.open,
    max_retries = opts.max_retries or 3,
    buffer = {},
    max_buffer = opts.max_buffer or 100,
    last_warning = nil,
  }

  function w:set_path(new_path)
    self.path = new_path
  end

  function w:flush_buffer()
    while #self.buffer > 0 do
      local line = self.buffer[1]
      local ok, err = self:_write_line(line)
      if not ok then
        self.last_warning = err or "write failed"
        return false, self.last_warning
      end
      table.remove(self.buffer, 1)
    end
    self.last_warning = nil
    return true
  end

  function w:_write_line(line)
    local last_err
    for _ = 1, self.max_retries do
      local f, err = self.io_open(self.path, "a+")
      if f then
        local wok, werr = f:write(line)
        f:close()
        if wok then return true end
        last_err = werr or "write error"
      else
        last_err = err or "open failed"
      end
    end
    return false, last_err
  end

  function w:append(event_tbl)
    local payload = "{" .. self.json_encode(event_tbl) .. "}\n"
    local ok, err = self:_write_line(payload)
    if ok then
      -- also try drain any prior buffer
      self:flush_buffer()
      return true
    end
    if #self.buffer < self.max_buffer then
      self.buffer[#self.buffer + 1] = payload
    end
    self.last_warning = err or "append failed"
    return false, self.last_warning
  end

  return w
end
