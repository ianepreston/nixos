-- Debug Adapter Protocol client implementation (attach to process, launch app to debug, set breakpoint, etc)
-- Note: it is so tied with its dependencies that all of them are defined here, in a single file
-- Stack-specific references: https://github.com/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation
-- https://github.com/mfussenegger/nvim-dap/

-- Terminology is confusing here, so here is a recap:
-- DAP-Client ----- Debug Adapter ------- Debugger ------ Debugee
-- (nvim-dap)  |   (per language)  |   (per language)    (your app)
--             |                   |
--             |        Implementation specific communication
--             |        Debug adapter and debugger could be the same process
--             |
--      Communication via the Debug Adapter Protocol

local PYTHON = require("utils.python").get_python()
local M = {
  "mfussenegger/nvim-dap",
  enabled = true,
  event = "VeryLazy",

  dependencies = {
    "nvim-neotest/nvim-nio",
    require "plugins.dap-conf.nvim-dap-ui",
    -- Displaying values of variables during debugging, highlighting changed variables, etc
    -- https://github.com/theHamsta/nvim-dap-virtual-text
    {
      "theHamsta/nvim-dap-virtual-text",
      enabled = true,
      opts = {},
    },
  },

  opts = {},

  config = function(_, opts)
    -- Set highlighting of a debugger-active line to the style of Visual mode highlighting
    vim.api.nvim_set_hl(0, "DapStoppedLine", { default = true, link = "Visual" })

    vim.fn.sign_define("DapBreakpoint", { text = " ", texthl = "DiagnosticSignError" })
    vim.fn.sign_define("DapBreakpointCondition", { text = " ", texthl = "DiagnosticSignError" })
    vim.fn.sign_define("DapBreakpointRejected", { text = " ", texthl = "DiagnosticSignError" })

    -- You can create your own configurations and adapters in a separate modules and require() them here
    -- or just put the code here like this (codelldb and c are just examples):
    -- For support of VS Code launch.json debug configurations, see `:h dap-launch.json`
    --
    local dap = require "dap"

    dap.adapters.python = {
      type = "executable",
      command = PYTHON, -- runs: python3 -m debugpy.adapter
      args = { "-m", "debugpy.adapter" },
    }

    dap.configurations.python = {
      -- Launch the current file
      {
        type = "python",
        request = "launch",
        name = "Launch file",
        program = "${file}", -- run the current buffer
        pythonPath = PYTHON,
        console = "internalConsole",
        justMyCode = false,
      },
    }
  end,
}

return M
