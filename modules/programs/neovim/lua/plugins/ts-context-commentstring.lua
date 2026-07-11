-- Context-aware `commentstring` (e.g. JSX/embedded languages) driven by
-- tree-sitter. Consumes the core `vim.treesitter` API + vendored queries, not
-- the archived nvim-treesitter Lua runtime.
-- https://github.com/JoosepAlviste/nvim-ts-context-commentstring

local M = {
  "JoosepAlviste/nvim-ts-context-commentstring",
  enabled = true,
  event = "VeryLazy",
  -- Skip the deprecated nvim-treesitter integration module (that path is the
  -- only place this plugin still `require`s nvim-treesitter). We only use the
  -- setup() API below.
  init = function()
    vim.g.skip_ts_context_commentstring_module = true
  end,
  config = function()
    require("ts_context_commentstring").setup {
      enable_autocmd = false,
    }
  end,
}

return M
