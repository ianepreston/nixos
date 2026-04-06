-- Parsing library. It can build a syntax tree for a source file and efficiently update it as the source file is edited
-- Note: try ctrl + space keybind for incremental selection, it's very nice
-- https://github.com/nvim-treesitter/nvim-treesitter

local M = {
  "nvim-treesitter/nvim-treesitter",
  enabled = true,
  build = ":TSUpdate",
  lazy = false,
  dependencies = {
    { "JoosepAlviste/nvim-ts-context-commentstring" },
    { "nvim-treesitter/nvim-treesitter-textobjects", branch = "main" },
    { "nvim-treesitter/nvim-treesitter-context", branch = "master" },
    { "nvim-tree/nvim-web-devicons" },
  },
}

function M.config()
  local ensure_installed = require("settings.toolset").ts_languages

  require("ts_context_commentstring").setup {
    enable_autocmd = false,
  }

  require("nvim-treesitter").setup({
    ensure_installed = ensure_installed,
    auto_install = true,
    sync_install = false,
    ignore_install = {},
  })

  -- Incremental selection
  vim.keymap.set("n", "<C-space>", function()
    require("nvim-treesitter.incremental_selection").init_selection()
  end, { desc = "Init treesitter selection" })
  vim.keymap.set("x", "<C-space>", function()
    require("nvim-treesitter.incremental_selection").node_incremental()
  end, { desc = "Increment treesitter selection" })
  vim.keymap.set("x", "<bs>", function()
    require("nvim-treesitter.incremental_selection").node_decremental()
  end, { desc = "Decrement treesitter selection" })

  -- Textobjects
  require("nvim-treesitter-textobjects").setup({
    select = {
      lookahead = true,
      keymaps = {
        ["ak"] = { query = "@block.outer", desc = "around block" },
        ["ik"] = { query = "@block.inner", desc = "inside block" },
        ["ac"] = { query = "@class.outer", desc = "around class" },
        ["ic"] = { query = "@class.inner", desc = "inside class" },
        ["a?"] = { query = "@conditional.outer", desc = "around conditional" },
        ["i?"] = { query = "@conditional.inner", desc = "inside conditional" },
        ["af"] = { query = "@function.outer", desc = "around function " },
        ["if"] = { query = "@function.inner", desc = "inside function " },
        ["al"] = { query = "@loop.outer", desc = "around loop" },
        ["il"] = { query = "@loop.inner", desc = "inside loop" },
        ["aa"] = { query = "@parameter.outer", desc = "around argument" },
        ["ia"] = { query = "@parameter.inner", desc = "inside argument" },
      },
    },
    move = {
      set_jumps = true,
      goto_next_start = {
        ["]k"] = { query = "@block.outer", desc = "Next block start" },
        ["]f"] = { query = "@function.outer", desc = "Next function start" },
        ["]a"] = { query = "@parameter.inner", desc = "Next argument start" },
      },
      goto_next_end = {
        ["]K"] = { query = "@block.outer", desc = "Next block end" },
        ["]F"] = { query = "@function.outer", desc = "Next function end" },
        ["]A"] = { query = "@parameter.inner", desc = "Next argument end" },
      },
      goto_previous_start = {
        ["[k"] = { query = "@block.outer", desc = "Previous block start" },
        ["[f"] = { query = "@function.outer", desc = "Previous function start" },
        ["[a"] = { query = "@parameter.inner", desc = "Previous argument start" },
      },
      goto_previous_end = {
        ["[K"] = { query = "@block.outer", desc = "Previous block end" },
        ["[F"] = { query = "@function.outer", desc = "Previous function end" },
        ["[A"] = { query = "@parameter.inner", desc = "Previous argument end" },
      },
    },
    swap = {
      swap_next = {
        [">K"] = { query = "@block.outer", desc = "Swap next block" },
        [">F"] = { query = "@function.outer", desc = "Swap next function" },
        [">A"] = { query = "@parameter.inner", desc = "Swap next argument" },
      },
      swap_previous = {
        ["<K"] = { query = "@block.outer", desc = "Swap previous block" },
        ["<F"] = { query = "@function.outer", desc = "Swap previous function" },
        ["<A"] = { query = "@parameter.inner", desc = "Swap previous argument" },
      },
    },
  })
end

return M
