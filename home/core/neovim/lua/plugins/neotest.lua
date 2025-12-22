-- Test runner
-- https://github.com/nvim-neotest/neotest
local PYTHON = require("utils.python").get_python()
local M = {
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "nvim-lua/plenary.nvim",
    "antoinemadec/FixCursorHold.nvim",
    "nvim-treesitter/nvim-treesitter",
    "nvim-neotest/neotest-python",
  },
  keys = {
    {
      "<leader>pr",
      function()
        require("neotest").run.run()
      end,
      mode = "n",
      desc = "Run nearest test",
    },
    {
      "<leader>pf",
      function()
        require("neotest").run.run(vim.api.nvim_buf_get_name(0))
      end,
      mode = "n",
      desc = "Run tests in current file",
    },
    {
      "<leader>pd",
      function()
        require("neotest").run.run { strategy = "dap" }
      end,
      mode = "n",
      desc = "Debug nearest test",
    },
    {
      "<leader>pw",
      function()
        require("neotest").watch()
      end,
      mode = "n",
      desc = "Watches files related to tests for changes and re-runs tests",
    },
    {
      "<leader>ps",
      function()
        require("neotest").summary.toggle()
      end,
      mode = "n",
      desc = "Displays test suite structure from project root. ",
    },
    {
      "<leader>pl",
      function()
        require("neotest").run.run_last()
      end,
      desc = "Run Last Test",
    },
    {
      "<leader>px",
      function()
        require("neotest").run.stop()
      end,
      desc = "Stop Test",
    },
    {
      "<leader>pa",
      function()
        require("neotest").run.run(vim.uv.cwd())
      end,
      desc = "Run All Tests in Project",
    },
    {
      "<leader>pp",
      function()
        require("neotest").output_panel.toggle()
      end,
      desc = "Toggle Output Panel",
    },
  },
}

function M.config()
  require("neotest").setup {
    adapters = {
      require "neotest-python" {
        -- Extra arguments for nvim-dap configuration
        -- See https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for values
        dap = {
          justMyCode = false,
          console = "integratedTerminal",
          subProcess = true,
          redirectOutput = false,
        },
        -- Command line arguments for runner
        -- Can also be a function to return dynamic values
        args = { "-s", "--log-level", "DEBUG" },
        -- Runner to use. Will use pytest if available by default.
        -- Can be a function to return dynamic value.
        runner = "pytest",
        -- Custom python path for the runner.
        -- Can be a string or a list of strings.
        -- Can also be a function to return dynamic value.
        -- If not provided, the path will be inferred by checking for
        -- virtual envs in the local directory and for Pipenev/Poetry configs
        python = PYTHON,
      },
      -- Returns if a given file path is a test file.
      -- NB: This function is called a lot so don't perform any heavy tasks within it.
    },
    -- VIRTUAL TEXT & DIAGNOSTICS CONFIG
    diagnostic = {
      enabled = true,
      severity = vim.diagnostic.severity.ERROR, -- Only show virtual text for errors
    },
    status = {
      enabled = true,
      virtual_text = true, -- Shows "Passed/Failed" next to test names
      signs = true, -- Shows icons in the sign column (gutter)
    },
    floating = {
      border = "rounded",
      max_height = 0.6,
      max_width = 0.6,
      options = {},
    },
  }
end

return M
