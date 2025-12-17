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

local M = {
  "mfussenegger/nvim-dap",
  enabled = true,
  event = "VeryLazy",

  dependencies = {
    "nvim-neotest/nvim-nio",

    -- An IDE-like UI for DAP (inspired by LunarVim/nvim-basic-ide)
    -- https://github.com/rcarriga/nvim-dap-ui
    {
      "rcarriga/nvim-dap-ui",
      enabled = true,
      opts = {
        expand_lines = true,
        icons = { expanded = "", collapsed = "", circular = "" },
        mappings = {
          -- Use a table to apply multiple mappings
          expand = { "<CR>", "<2-LeftMouse>" },
          open = "o",
          remove = "d",
          edit = "e",
          repl = "r",
          toggle = "t",
        },
        layouts = {
          {
            elements = {
              { id = "scopes", size = 0.33 },
              { id = "breakpoints", size = 0.17 },
              { id = "stacks", size = 0.25 },
              { id = "watches", size = 0.25 },
            },
            size = 0.33,
            position = "right",
          },
          {
            elements = {
              { id = "repl", size = 0.45 },
              { id = "console", size = 0.55 },
            },
            size = 0.27,
            position = "bottom",
          },
        },
        floating = {
          max_height = 0.9,
          max_width = 0.5, -- Floats will be treated as percentage of your screen.
          border = vim.g.border_chars, -- Border style. Can be 'single', 'double' or 'rounded'
          mappings = {
            close = { "q", "<Esc>" },
          },
        },
      },
      config = function(_, opts)
        local dap = require "dap"
        local dapui = require "dapui"
        dapui.setup(opts)
        dap.listeners.after.event_initialized["dapui_config"] = function()
          dapui.open {}
        end
        dap.listeners.before.event_terminated["dapui_config"] = function()
          dapui.close {}
        end
        dap.listeners.before.event_exited["dapui_config"] = function()
          dapui.close {}
        end
      end,
    },

    -- Displaying values of variables during debugging, highlighting changed variables, etc
    -- https://github.com/theHamsta/nvim-dap-virtual-text
    {
      "theHamsta/nvim-dap-virtual-text",
      enabled = true,
      opts = {},
    },
  },
  -- End of dependencies, back to the dap itself

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

    -- Choose the python executable to run the adapter.
    -- With Nix, prefer an explicit path (replace with your own, e.g., /nix/store/.../bin/python3)
    -- If your shell PATH already has the Nix python3, "python3" is fine.
    local python_path = vim.fn.exepath "python3" ~= "" and "python3" or "python"

    dap.adapters.python = {
      type = "executable",
      command = python_path, -- runs: python3 -m debugpy.adapter
      args = { "-m", "debugpy.adapter" },
    }

    dap.configurations.python = {
      -- Launch the current file
      {
        type = "python",
        request = "launch",
        name = "Launch file",
        program = "${file}", -- run the current buffer
        pythonPath = function()
          -- Prefer project venv if present; otherwise fall back to adapter python
          local venv = vim.fn.getcwd() .. "/.venv/bin/python"
          if vim.fn.filereadable(venv) == 1 then
            return venv
          end
          return python_path
        end,
        console = "internalConsole",
        justMyCode = false,
      },
    }
  end,
}

return M
