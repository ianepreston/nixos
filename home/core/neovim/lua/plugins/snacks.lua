local M = {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    input = {
      enabled = true,
    },
    picker = {
      enabled = true,
      ui_select = true,
    },
    bufdelete = { enabled = true },
  },
}

function M.config(_, opts)
  require("snacks").setup(opts)
end

return M
