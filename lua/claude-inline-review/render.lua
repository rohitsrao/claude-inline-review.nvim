-- render.lua: painting hunks over a real buffer with extmarks. New lines get a
-- green background; old lines are red virtual lines, display-only.
local config = require("claude-inline-review.config")
local hunks = require("claude-inline-review.hunks")

local M = {}

M.ns = vim.api.nvim_create_namespace("claude_inline_review")

function M.define_highlights()
  local set = function(name, link) vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
  set("ClaudeInlineReviewAdd", "DiffAdd")
  set("ClaudeInlineReviewDelete", "DiffDelete")
  set("ClaudeInlineReviewAddCurrent", "DiffText")
  set("ClaudeInlineReviewDeleteCurrent", "DiffDelete")
  set("ClaudeInlineReviewSign", "DiagnosticWarn")
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

-- Old lines padded to the window width, so the red runs edge to edge.
local function virt_lines(buf, lines, hl, width)
  local result = {}
  for _, line in ipairs(lines) do
    local text = line:gsub("\t", string.rep(" ", vim.bo[buf].tabstop))
    local pad = math.max(width - vim.fn.strdisplaywidth(text), 0)
    result[#result + 1] = { { text .. string.rep(" ", pad), hl } }
  end
  return result
end

-- Draws `list` (hunks of `old` against the buffer); `current` is the index of
-- the hunk the keys act on, or nil.
function M.draw(buf, list, old, current)
  M.clear(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local width = vim.o.columns

  for i, h in ipairs(list) do
    local is_current = i == current
    local add_hl = is_current and "ClaudeInlineReviewAddCurrent" or "ClaudeInlineReviewAdd"
    local del_hl = is_current and "ClaudeInlineReviewDeleteCurrent" or "ClaudeInlineReviewDelete"

    for row = h.new_start, h.new_start + h.new_count - 1 do
      vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, 0, { line_hl_group = add_hl, priority = 150 })
    end

    if h.old_count > 0 then
      local row, above
      if h.new_count > 0 or h.new_start == 0 then
        row, above = math.max(h.new_start, 1) - 1, true
      else
        row, above = h.new_start - 1, false
      end
      row = math.min(row, line_count - 1)
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        virt_lines = virt_lines(buf, hunks.old_slice(old, h), del_hl, width),
        virt_lines_above = above,
      })
    end

    if is_current then
      local first = hunks.rows(h)
      vim.api.nvim_buf_set_extmark(buf, M.ns, math.min(first, line_count) - 1, 0, {
        sign_text = config.options.sign,
        sign_hl_group = "ClaudeInlineReviewSign",
        priority = 100,  -- above gitsigns' signs
      })
    end
  end
end

return M
