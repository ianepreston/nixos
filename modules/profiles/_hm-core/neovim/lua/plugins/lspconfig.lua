-- "Easy configuration" wrapper around builtin LSP (LspInfo, LspStop, multi-root support useful for memory-hungry LSP servers, etc)
-- Sets up each of `lsp_servers` from `lua/settings/toolset.lua`. Does NOT install any LSP servers, only configures them.
-- If you want to install LSP servers with Mason, check `lsp_mason_install` in `lua/settings/toolset.lua` and
-- `lua/plugins/mason.lua` instead.
-- https://github.com/neovim/nvim-lspconfig

-- lua/plugins/lsp.lua
local M = {
  "neovim/nvim-lspconfig",
  enabled = true,
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "hrsh7th/cmp-nvim-lsp",
    "folke/neodev.nvim",
    "b0o/schemastore.nvim",
  },
  opts = {
    inlay_hints = { enabled = true }, -- we'll wire this via LspAttach below
  },
}

function M.config(_, opts)
  -- 1) Global defaults for ALL servers (0.11 style)
  vim.lsp.config("*", {
    capabilities = require("cmp_nvim_lsp").default_capabilities(), -- snippet & cmp support
  })

  -- 2) Enable all servers listed in your toolset (Neovim will merge lsp/<server>.lua)
  local servers = {}
  for _, s in ipairs(require("settings.toolset").lsp_servers) do
    local name = vim.split(s, "@")[1] -- strip optional version suffix
    table.insert(servers, name)
  end
  vim.lsp.enable(servers)

  -- 3) Diagnostics: minimal, lower-churn setup
  local signs = {
    { name = "DiagnosticSignError", text = "" },
    { name = "DiagnosticSignWarn", text = "" },
    { name = "DiagnosticSignHint", text = "" },
    { name = "DiagnosticSignInfo", text = "" },
  }
  for _, sign in ipairs(signs) do
    vim.fn.sign_define(sign.name, { texthl = sign.name, text = sign.text, numhl = "" })
  end

  vim.diagnostic.config {
    virtual_text = true, -- consider turning off if you prefer floating only
    signs = { active = signs },
    update_in_insert = false, -- reduces redraw/CPU while typing
    underline = true,
    severity_sort = true,
    float = {
      focusable = false,
      style = "minimal",
      border = "rounded",
      source = "if_many",
      header = "",
      prefix = "",
      suffix = "",
    },
  }

  -- 4) Inlay hints: enable on attach (only if server supports it)
  if opts.inlay_hints and opts.inlay_hints.enabled then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("UserInlayHints", { clear = true }),
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if client and client.server_capabilities.inlayHintProvider then
          -- Either of these forms works:
          vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
          -- or
          -- vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
        end
      end,
    })
  end
end

return M
