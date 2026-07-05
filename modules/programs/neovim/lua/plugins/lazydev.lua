-- Signature help, docs and completion for the Neovim Lua API
-- Successor to the archived folke/neodev.nvim
-- https://github.com/folke/lazydev.nvim

return {
  "folke/lazydev.nvim",
  ft = "lua",
  opts = {
    library = {
      -- Load luvit types when the `vim.uv` word is found
      { path = "${3rd}/luv/library", words = { "vim%.uv" } },
    },
  },
}
