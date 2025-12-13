-- Bufferline to show open buffers with neovim tabs integration
-- https://github.com/akinsho/bufferline.nvim

local M = {
  "akinsho/bufferline.nvim",
  enabled = true,
  event = { "BufReadPre", "BufAdd", "BufNew", "BufReadPost" },
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  keys = {
    {
      "<leader>.",
      mode = "n",
      function()
        require("bufferline").pick()
      end,
      desc = "Quick pick buffer",
    },
  },
  opts = {
    options = {
      close_command = function(n)
        require("snacks").bufdelete.delete(n, { force = false })
      end,
      right_mouse_command = function(n)
        require("snacks").bufdelete.delete(n, { force = false })
      end,

      separator_style = "thin", -- | "thick" | "thin" | { 'any', 'any' },
      buffer_close_icon = "",

      offsets = {
        {
          filetype = "neo-tree",
          text = "Neo-tree",
          highlight = "Directory",
          text_align = "left",
        },
        { filetype = "snacks_layout_box" },
      },

      show_close_icon = false,
      show_buffer_close_icons = false,
    },
  },
}

function M.config(_, opts)
  require("bufferline").setup(opts)
end

return M
