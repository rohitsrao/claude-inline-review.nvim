-- recover.lua: :ClaudeInlineReview recover <path> <sha>, for the SHA printed
-- when the mod stopped Claude because it could not record a change.
local git = require("claude-inline-review.git")
local review = require("claude-inline-review.review")

local M = {}

function M.run(path, sha)
  local S = review.state
  if not S.top then
    return vim.notify("claude-inline-review: not in a git repo", vim.log.levels.WARN)
  end
  if not path or not sha then
    return vim.notify("Usage: :ClaudeInlineReview recover <path> <sha>", vim.log.levels.WARN)
  end

  local ok, text = pcall(git.cat_file, S.top, sha)
  if not ok then
    return vim.notify("claude-inline-review: " .. text, vim.log.levels.ERROR)
  end

  review.reload()
  local rel = review.rel_of(path) or path

  -- The record survived (a failure stop keeps it): the SHA becomes the
  -- file's baseline and the review carries on hunk by hunk.
  if S.session and S.session.files[rel] then
    S.review.baselines[rel] = sha
    review.save_review()
    return review.start()
  end

  -- No record to join: show the snapshot beside the file as a diff.
  vim.cmd.edit(vim.fn.fnameescape(review.abs(rel)))
  vim.cmd("vertical new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, require("claude-inline-review.hunks").lines(text))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, ("claude-inline-review://%s@%s"):format(rel, sha:sub(1, 8)))
  vim.cmd("diffthis | wincmd p | diffthis")
end

return M
