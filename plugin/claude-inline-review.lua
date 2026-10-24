-- :ClaudeInlineReview [start|stop|list|refresh|recover <path> <sha>|install-mod]
if vim.g.loaded_claude_inline_review then return end
vim.g.loaded_claude_inline_review = true

local subcommands = {
  start = function() require("claude-inline-review.review").start() end,
  stop = function() require("claude-inline-review.review").quit() end,
  list = function() require("claude-inline-review.review").list() end,
  refresh = function()
    local git = require("claude-inline-review.git")
    git.async(function()
      require("claude-inline-review.review").on_record_change()
      require("claude-inline-review.commits").check()
    end)
  end,
  recover = function(args) require("claude-inline-review.recover").run(args[2], args[3]) end,
  ["install-mod"] = function() require("claude-inline-review.install").run() end,
}

vim.api.nvim_create_user_command("ClaudeInlineReview", function(cmd)
  local name = cmd.fargs[1] or "start"
  local run = subcommands[name]
  if not run then
    return vim.notify("ClaudeInlineReview: unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  run(cmd.fargs)
end, {
  nargs = "*",
  desc = "Review Claude's file edits",
  complete = function(_, line)
    if #vim.split(line, "%s+", { trimempty = true }) > 2 then return {} end
    return vim.tbl_keys(subcommands)
  end,
})
