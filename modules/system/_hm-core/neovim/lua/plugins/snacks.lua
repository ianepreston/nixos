local M = {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    bufdelete = { enabled = true },
    dashboard = {
      enabled = true,
      sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1 },
        {
          pane = 2,
          icon = " ",
          title = "Recent Files",
          section = "recent_files",
          indent = 2,
          padding = 1,
          cwd = true,
        },
        { pane = 2, icon = " ", title = "Projects", section = "projects", indent = 2, padding = 1 },
        {
          pane = 2,
          icon = " ",
          title = "Git Status",
          section = "terminal",
          enabled = function()
            return require("snacks").git.get_root() ~= nil
          end,
          cmd = "git status --short --branch --renames",
          height = 5,
          padding = 1,
          ttl = 5 * 60,
          indent = 3,
        },
        { section = "startup" },
      },
    },
    input = {
      enabled = true,
    },
    lazygit = {},
    picker = {
      enabled = true,
      ui_select = true,
    },
    terminal = {},
  },
}

function M.config(_, opts)
  require("snacks").setup(opts)
end

return M
