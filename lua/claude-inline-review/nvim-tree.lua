-- nvim-tree.lua: a Decorator that shows pending hunks per file (●3) and a dot
-- on folders with anything pending. Add it to nvim-tree's renderer.decorators:
--
--   renderer = { decorators = { "Git", "Open", "Hidden", "Modified", "Bookmark",
--     "Diagnostics", "Copied", "Cut", require("claude-inline-review.nvim-tree").decorator } }
local M = {}

local ok, api = pcall(require, "nvim-tree.api")
if not ok or not api.Decorator then
  return M
end

local Decorator = api.Decorator:extend()

function Decorator:new()
  self.enabled = true
  self.highlight_range = "none"
  self.icon_placement = "after"
end

function Decorator:icons(node)
  local counts = require("claude-inline-review.review").counts()
  local path = node.absolute_path
  if not path then return nil end

  local n = counts[path]
  if n then
    return { { str = "●" .. n, hl = { "ClaudeInlineReviewSign" } } }
  end

  if node.type == "directory" then
    local prefix = path .. "/"
    for file in pairs(counts) do
      if vim.startswith(file, prefix) then
        return { { str = "●", hl = { "ClaudeInlineReviewSign" } } }
      end
    end
  end
  return nil
end

M.decorator = Decorator

return M
