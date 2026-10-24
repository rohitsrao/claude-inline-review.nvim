-- nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = vim.env.PLENARY or vim.fn.expand("~/.local/share/nvim/site/pack/core/opt/plenary.nvim")

vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")

vim.o.swapfile = false
vim.o.undofile = false
vim.o.hidden = true
