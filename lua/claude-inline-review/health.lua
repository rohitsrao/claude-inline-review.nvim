-- health.lua: :checkhealth claude-inline-review
local install = require("claude-inline-review.install")

local M = {}

-- This plugin's version: the mod's plugin.json in the same checkout.
local function own_version()
  local source = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local file = io.open(root .. "/claude-mod/.claude-plugin/plugin.json", "r")
  if not file then return nil end
  local ok, manifest = pcall(vim.json.decode, file:read("*a"))
  file:close()
  return ok and manifest.version or nil
end

function M.check()
  local health = vim.health
  health.start("claude-inline-review")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.11 or newer is required (vim.text.diff)")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git found")
  else
    health.error("git not found on PATH")
  end

  local version = own_version()
  local review = require("claude-inline-review.review").state
  if review.top then
    health.ok("Repo: " .. review.top)
  else
    health.info("Not in a git repo right now (the review is off here)")
  end

  if vim.fn.executable("claude") == 0 then
    health.warn("`claude` CLI not found; can't check the mod")
  else
    local list = vim.system({ "claude", "plugin", "list" }, { text = true }):wait(15000)
    if list.code == 0 and (list.stdout or ""):find(install.MOD, 1, true) then
      health.ok(("Claude Code mod %s is installed"):format(install.MOD))
    else
      health.warn(("Claude Code mod %s is not installed"):format(install.MOD), {
        "Run :ClaudeInlineReview install-mod",
        ("or at the Claude prompt: /plugin install %s --marketplace %s"):format(install.MOD, install.REPO),
      })
    end
  end

  local mod_version = review.session and review.session.modVersion
  if mod_version and version and mod_version ~= version then
    health.warn(("The mod is %s but this plugin is %s"):format(mod_version, version), {
      ("Run: claude plugin update %s@%s"):format(install.MOD, install.MOD),
    })
  elseif mod_version then
    health.ok("Mod and plugin versions match (" .. mod_version .. ")")
  end

  local file = io.open(vim.fs.normalize("~/.claude.json"), "r")
  local diff_tool
  if file then
    local ok, settings = pcall(vim.json.decode, file:read("*a"))
    file:close()
    diff_tool = ok and type(settings) == "table" and settings.diffTool or nil
  end
  if diff_tool == "terminal" then
    health.ok("Claude Code diffTool is \"terminal\" (no per-edit diff in Neovim)")
  else
    health.warn("Claude Code's diffTool is not \"terminal\": each edit may open a diff in Neovim", {
      "At the Claude prompt: /config diffTool=terminal",
      "and use acceptEdits mode (Shift+Tab) so edits apply without asking",
    })
  end
end

return M
