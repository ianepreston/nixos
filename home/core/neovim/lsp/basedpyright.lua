local opts = {
  settings = {
    python = {
      pythonPath = vim.fn.exepath "python", -- resolves from PATH at startup
      analysis = {
        autoSearchPaths = true,
        useLibraryCodeForTypes = true,
        diagnosticMode = "openFilesOnly",
        -- You can soften this while testing:
        -- diagnosticSeverityOverrides = { reportMissingModuleSource = "information" },
      },
    },
    basedpyright = {
      analysis = {
        typeCheckingMode = "recommended",
      },
    },
  },
}

return opts
