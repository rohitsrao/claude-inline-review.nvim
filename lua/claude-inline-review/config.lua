-- config.lua: defaults, merged with what setup() is given.
local M = {}

M.defaults = {
  -- Any key set to false is left unmapped.
  keymaps = {
    start = "<leader>rr",       -- start / resume the review (global)
    next_hunk = "]h",           -- the rest are buffer-local during a review
    prev_hunk = "[h",
    accept = "<leader>ra",
    reject = "<leader>rx",
    accept_file = "<leader>rA",
    reject_file = "<leader>rX",
    list = "<leader>rl",
    quit = "<leader>rq",
  },
  debounce_ms = {
    record = 200,  -- session.json changes
    reflog = 300,  -- commits (logs/HEAD)
    render = 150,  -- repaint after typing, u or <C-r>
  },
  sign = "▶",      -- marks the hunk your keys act on
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
