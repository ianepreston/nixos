local g = vim.g
local opt = vim.opt

-- Mason is used to grab LSP, Debug, and linting tools specified in settings/toolset.lua
-- Disabling Mason is useful when you manage tools yourself (system-wide packages, Nix shells or nix-managed system, etc)
-- People prefer having Mason enabled on tradional non-atomic/non-reproducible systems like Arch or Debian without Nix on them
g.mason_enabled = false

-- Pre-installed themes and their styles/variants:
--   catppuccin: latte, frappe, macchiato, mocha
--   monokai-pro: classic, octagon, pro, machine, ristretto, spectrum
--   tokyonight: storm, moon, night, day
--   gruvbox: hard, soft, "" (empty line for default contrast)
--   onedark: dark, darker, cool, deep, warm, warmer, light
g.eden_transparent = true -- makes the background of g.eden_theme transparent (wrt terminal opacity)
g.eden_theme = "catppuccin" -- edenvim-specific theme name (look lua/plugins/colorscheme.lua)
g.eden_theme_variant = "latte" -- theme variant for g.eden_theme. comment to use the default variant for each theme

g.eden_header = "small" -- "big" or "small" header

g.mapleader = " " -- leader key for keymaps

opt.guifont = "monospace:h12" -- font used in Neovim GUI apps like Neovide

vim.o.background = "light"
-- Hide '~' shown on every line after EOF by replacing it with ' ', improve fold charasters
---@diagnostic disable-next-line: assign-type-mismatch
opt.fillchars = "eob: ,fold: ,foldopen:,foldsep: ,foldclose:"
opt.foldcolumn = "auto" -- Width of fold column (if you use folds a lot, better set to "1" and install nvim-ufo)

opt.backup = false -- creates a backup file
opt.clipboard = "unnamedplus" -- allows neovim to access the system clipboard
opt.cmdheight = 0 -- more space in the neovim command line for displaying messages
opt.completeopt = { "menuone", "noselect" } -- mostly just for cmp
opt.conceallevel = 0 -- so that `` is visible in markdown files
opt.fileencoding = "utf-8" -- the encoding written to a file
opt.hlsearch = true -- highlight all matches on previous search pattern
opt.ignorecase = true -- ignore case in search patterns
opt.mouse = "a" -- allow the mouse to be used in neovim
opt.pumheight = 10 -- pop up menu height
opt.showmode = false -- we don't need to see things like -- INSERT -- anymore
opt.showtabline = 0 -- always show tabs
opt.smartcase = true -- smart case
opt.smartindent = true -- make indenting smarter again
opt.splitbelow = true -- force all horizontal splits to go below current window
opt.splitright = true -- force all vertical splits to go to the right of current window
opt.swapfile = false -- creates a swapfile
opt.termguicolors = true -- set term gui colors (most terminals support this)
opt.timeout = true
opt.timeoutlen = 300 -- time to wait for a mapped sequence to complete (in milliseconds)
opt.undofile = true -- enable persistent undo
opt.updatetime = 300 -- faster completion (4000ms default)
opt.writebackup = false -- if a file is being edited by another program (or was written to file while editing with another program), it is not allowed to be edited
opt.expandtab = true -- convert tabs to spaces
opt.shiftwidth = 2 -- the number of spaces inserted for each indentation
opt.tabstop = 2 -- insert 2 spaces for a tab
opt.cursorline = true -- highlight the current line
opt.number = true -- set numbered lines
opt.relativenumber = true -- set relative line numbers (absolute + relative = hybrid)
opt.laststatus = 3 -- only the last window will always have a status line
opt.showcmd = true -- don't hide partial command in the last line of the screen (although bad for performance)
opt.ruler = false -- hide the line and column number of the cursor position
opt.numberwidth = 4 -- minimal number of columns to use for the line number {default 4}
opt.signcolumn = "yes" -- always show the sign column, otherwise it would shift the text each time
opt.wrap = false -- display lines as one long line (line wrapping)
opt.scrolloff = 8 -- minimal number of screen lines to keep above and below the cursor
opt.sidescrolloff = 8 -- minimal number of screen columns to keep to the left and right of the cursor if wrap is `false`
opt.shortmess:append "c" -- hide all the completion messages, e.g. "-- XXX completion (YYY)", "match 1 of 2", "The only match", "Pattern not found"
opt.whichwrap:append "<,>,[,],h,l" -- keys allowed to move to the previous/next line when the beginning/end of line is reached
opt.iskeyword:append "-" -- treats words with `-` as single words
opt.formatoptions:remove { "c", "r", "o" } -- This is a sequence of letters which describes how automatic formatting is to be done
opt.linebreak = true
-- opt.colorcolumn = {80, 120}                 -- set line width indication at columns 80 and 120
opt.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"
vim.lsp.set_log_level "off" -- LSP log gets huge and I don't care about it

--- Get quarto to work as markdown
vim.filetype.add {
  extension = { qmd = "markdown" },
}
-- Next, please see settings/toolset.lua for a list of tools that are installed by default
-- The dashboard (starting page) can be customized in in settings/dashboard.lua
-- Keymaps can be customized in settings/keymaps.lua
