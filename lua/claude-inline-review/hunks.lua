-- hunks.lua: diffing a baseline against the current text, and applying one
-- hunk either way. Pure functions over lists of lines.
local M = {}

-- Text to lines; a final newline does not make an extra empty line.
function M.lines(text)
  if text == nil or text == "" then return {} end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

function M.text(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

-- A buffer's lines; an empty buffer holds one empty line, which means none.
function M.buf_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then return {} end
  return lines
end

-- Each hunk: `old_count` baseline lines at `old_start` became `new_count`
-- current lines at `new_start`. A count of 0 means "after line <start>".
function M.compute(old, new)
  local result = vim.text.diff(M.text(old), M.text(new), {
    result_type = "indices",
    algorithm = "histogram",
  })
  local hunks = {}
  for _, h in ipairs(result) do
    hunks[#hunks + 1] = { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] }
  end
  return hunks
end

function M.old_slice(old, h)
  return vim.list_slice(old, h.old_start, h.old_start + h.old_count - 1)
end

-- The baseline with hunk `h` accepted: its current lines take the old ones' place.
function M.accept(old, new, h)
  local result = {}
  local keep = h.old_count > 0 and h.old_start - 1 or h.old_start
  for i = 1, keep do result[#result + 1] = old[i] end
  for i = h.new_start, h.new_start + h.new_count - 1 do result[#result + 1] = new[i] end
  for i = keep + h.old_count + 1, #old do result[#result + 1] = old[i] end
  return result
end

-- The current lines with hunk `h` rejected: its old lines take the new ones' place.
function M.reject(old, new, h)
  local result = {}
  local keep = h.new_count > 0 and h.new_start - 1 or h.new_start
  for i = 1, keep do result[#result + 1] = new[i] end
  vim.list_extend(result, M.old_slice(old, h))
  for i = keep + h.new_count + 1, #new do result[#result + 1] = new[i] end
  return result
end

-- The buffer rows (1-based, inclusive) a hunk occupies. A pure deletion sits
-- between two lines, so it counts for the lines on both sides.
function M.rows(h)
  if h.new_count > 0 then
    return h.new_start, h.new_start + h.new_count - 1
  end
  return math.max(h.new_start, 1), h.new_start + 1
end

-- The hunk under row `row`, else the next one below it, else the first.
function M.index_at(hunks, row)
  for i, h in ipairs(hunks) do
    local _, last = M.rows(h)
    if row <= last then return i end
  end
  return #hunks > 0 and 1 or nil
end

return M
