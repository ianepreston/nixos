return {
  "stevearc/conform.nvim",
  event = { "BufWritePre" },
  cmd = { "ConformInfo" },
  -- keys = {
  --   {
  --     -- Customize or remove this keymap to your liking
  --     "<leader>f",
  --     function()
  --       require("conform").format({ async = true })
  --     end,
  --     mode = "",
  --     desc = "Format buffer",
  --   },
  -- },
  -- This will provide type hinting with LuaLS
  ---@module "conform"
  opts = {
    -- Define your formatters
    formatters_by_ft = {
      lua = { "stylua" },
      python = { "ruff_fix", "ruff_format" },
      nix = { "nixfmt" },
      yaml = { "yamlfmt" },
      tf = { "tfmt" },
      terraform = { "tfmt" },
      tfvars = { "tfmt" },
      javascript = { "prettierd" },
      sh = { "shfmt" },
      bash = { "shfmt" },
      markdown = { "prettier" },
    },
    -- Set default options
    default_format_opts = {
      lsp_format = "fallback",
    },
    -- Set up format-on-save
    format_on_save = { timeout_ms = 1000 },
    -- Customize formatters
    formatters = {
      prettier = {
        -- Enforce global Markdown wrapping:
        -- Wrap prose and set your desired column width (change 80 as needed).
        prepend_args = {
          "--prose-wrap",
          "always",
          "--print-width",
          "80",
        },
      },

      shfmt = {
        prepend_args = { "-i", "2" },
      },
      tfmt = {
        command = "tofu",
        args = { "fmt", "-" },
        stdin = true,
      },
    },
  },
  init = function()
    -- If you want the formatexpr, here is the place to set it
    vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"
  end,
}
