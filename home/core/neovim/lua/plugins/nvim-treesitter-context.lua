--- Code folding so section/function/class signatures are still visible

local M = {
  "nvim-treesitter/nvim-treesitter-context",
  event = "VeryLazy",
  config = function()
    require("treesitter-context").setup {
      enable = true, -- Ensure this is set to true for automatic enabling
      -- Your other configuration options can remain here
    }
    -- No need to manually enable it here if 'enable = true' is set
    -- vim.cmd('TSContextEnable')
  end,
}
return M
