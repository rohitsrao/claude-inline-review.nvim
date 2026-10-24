-- install.lua: :ClaudeInlineReview install-mod, the Claude Code side.
local M = {}

M.REPO = "rohitsrao/claude-inline-review.nvim"
M.MOD = "nvim-inline-review"

M.COMMANDS = {
  { "claude", "plugin", "marketplace", "add", M.REPO },
  { "claude", "plugin", "install", M.MOD .. "@" .. M.MOD },
}

function M.run()
  if vim.fn.executable("claude") == 0 then
    return vim.notify("claude-inline-review: the `claude` CLI is not on PATH", vim.log.levels.ERROR)
  end

  local shown = vim.tbl_map(function(argv) return "  " .. table.concat(argv, " ") end, M.COMMANDS)
  local msg = "Install the Claude Code mod by running:\n\n" .. table.concat(shown, "\n") .. "\n\nRun them now?"
  if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end

  local function step(i)
    local argv = M.COMMANDS[i]
    if not argv then
      return vim.notify("claude-inline-review: mod installed. It applies to Claude sessions started from now on.")
    end
    vim.system(argv, { text = true }, vim.schedule_wrap(function(result)
      local out = vim.trim((result.stdout or "") .. "\n" .. (result.stderr or ""))
      -- Adding a marketplace that is already there is not a failure.
      if result.code ~= 0 and not (i == 1 and out:find("already", 1, true)) then
        return vim.notify(("claude-inline-review: `%s` failed:\n%s"):format(table.concat(argv, " "), out),
          vim.log.levels.ERROR)
      end
      step(i + 1)
    end))
  end
  step(1)
end

return M
