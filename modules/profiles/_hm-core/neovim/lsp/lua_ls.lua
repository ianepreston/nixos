local opts = {
  settings = {
    Lua = {
      diagnostics = {
        globals = { "vim" },
      },
      codeLens = {
        enable = true,
      },
      hint = {
        enable = true,
        setType = false,
        paramType = true,
        paramName = "Disable",
        semicolon = "Disable",
        arrayIndex = "Disable",
      },
      workspace = {

        library = {
          vim.fn.expand "$VIMRUNTIME/lua",
          vim.fn.stdpath "config" .. "/lua",
          "${3rd}/luv/library",
        },

        -- Slightly less correct way to fix the issue mentioned above. Uncomment if can't configure above
        -- checkThirdParty = false,
      },
      telemetry = {
        enable = false,
      },
    },
  },
}

return opts
