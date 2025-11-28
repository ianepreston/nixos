-- Clone lazy.nvim if not found in system
local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

local opts = {
  install = {
    -- install missing plugins on startup. This doesn't increase startup time.
    missing = true,
    -- try to load one of these colorschemes when starting an installation during startup
    colorscheme = { require("colorschemes.gruvbox").name },
  },
  defaults = {
    -- Set this to `true` to have all your plugins lazy-loaded by default.
    -- Only do this if you know what you are doing, as it can lead to unexpected behavior.
    lazy = true,
  },
  change_detection = {
    -- automatically check for config file changes and reload the ui
    enabled = true,
    notify = true, -- get a notification when changes are found
  },
  -- automatically check for plugin updates
  checker = {
    -- automatically check for plugin updates
    enabled = true,
    concurrency = nil, ---@type number? set to 1 to check for updates very slowly
    notify = true, -- get a notification when new updates are found
    frequency = 3600, -- check for updates every hour
    check_pinned = false, -- check for pinned packages that can't be updated
  },
  debug = false,
  performance = {
    cache = {
      enabled = true,
    },
    reset_packpath = true, -- reset the package path to improve startup time
    rtp = {
      disabled_plugins = {
        -- -- Disabled in many distros to cut few msec of startup time, but it allows remote development:
        -- -- `nvim scp://root@server//etc/nginx/` will open a remote folder and sync changes, pure ssh
        -- "netrwPlugin",
        "gzip",
        "tarPlugin",
        "zipPlugin",
        "tohtml",
        -- "matchit",
        -- "matchparen",
        -- "tutor",
      },
    },
  },
}

-- all *.lua files within each directory specified here are considered plugin files
-- Note: if you want to include plugins/subfolder/*.lua files, add { import = "plugins/subfolder" }
local import_dirs = {
  { import = "colorschemes" },
  { import = "plugins" },
}

require("lazy").setup(import_dirs, opts)
