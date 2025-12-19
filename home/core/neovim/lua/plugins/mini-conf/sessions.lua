-- Move any selection in any direction (smart: reindents vertical movements, respects v:count, etc)
local M = {
  -- Whether to read latest session if Neovim opened without file arguments
  autoread = false,

  -- Whether to write current session before quitting Neovim
  autowrite = true,

  -- Directory where global sessions are stored (use `''` to disable)
  -- Note: "data" is not just XDG_DATA_HOME, see https://neovim.io/doc/user/starting.html#standard-path
  directory = vim.fn.stdpath "data" .. "/sessions/",

  -- File for local session
  -- Note: I prefer .session.vim, but some plugins (including tmux-resurrect) expect Session.vim
  file = "Session.vim",

  -- Whether to force possibly harmful actions (meaning depends on function)
  force = { read = false, write = true, delete = false },

  -- Hook functions for actions. Default `nil` means 'do nothing'.
  hooks = {
    -- Before successful action
    pre = { read = nil, write = nil, delete = nil },
    -- After successful action
    post = { read = nil, write = nil, delete = nil },
  },

  -- Whether to print session path after action
  verbose = { read = false, write = true, delete = true },
}
return M
