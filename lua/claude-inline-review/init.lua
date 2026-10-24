-- claude-inline-review: review Claude Code's file edits hunk by hunk in your
-- real buffers. The Claude Code mod (claude-mod/) records a snapshot of each
-- file before Claude's first touch; this plugin diffs it against the buffer.
local commits = require("claude-inline-review.commits")
local config = require("claude-inline-review.config")
local git = require("claude-inline-review.git")
local render = require("claude-inline-review.render")
local review = require("claude-inline-review.review")
local watch = require("claude-inline-review.watch")

local M = {}

local function on_record()
  git.async(function() review.on_record_change() end)
end

local function on_reflog()
  git.async(function() commits.check() end)
end

-- Follows Neovim's working directory into its repo.
function M.attach_repo(dir)
  local top, git_dir = git.repo(dir or vim.fn.getcwd())
  if top == review.state.top and git_dir == review.state.git_dir then return end

  watch.stop()
  review.set_repo(top, git_dir)
  if not top then return end

  watch.start(git_dir, on_record, on_reflog)
  -- Catches up on what happened while Neovim was closed, quietly.
  git.async(function() review.on_record_change({ startup = true }) end)
end

function M.setup(opts)
  config.set(opts)
  render.define_highlights()

  local group = vim.api.nvim_create_augroup("claude_inline_review", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = render.define_highlights })
  vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function() M.attach_repo() end })
  -- Watchers can miss events, and some repos turn the reflog off.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      on_record()
      on_reflog()
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev) review.on_buf_enter(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = watch.stop })

  local start = config.options.keymaps.start
  if start then
    vim.keymap.set("n", start, review.start, { desc = "Start / resume Claude review", silent = true })
  end

  M.attach_repo()
end

return M
