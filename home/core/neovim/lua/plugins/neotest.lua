-- Test runner
-- https://github.com/nvim-neotest/neotest
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
        require("neotest").run.run(vim.fn.expand "%")
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
      "<leader>po",
      function()
        require("neotest").output()
      end,
      mode = "n",
      desc = "Displays output of tests",
    },
    {
      "<leader>ps",
      function()
        require("neotest").summary()
      end,
      mode = "n",
      desc = "Displays test suite structure from project root. ",
    },
  },
}

function M.config()
  require("neotest").setup {
    adapters = {
      require "neotest-python" {
        -- Extra arguments for nvim-dap configuration
        -- See https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for values
        dap = { justMyCode = false },
        -- Command line arguments for runner
        -- Can also be a function to return dynamic values
        args = { "--log-level", "DEBUG" },
        -- Runner to use. Will use pytest if available by default.
        -- Can be a function to return dynamic value.
        runner = "pytest",
        -- Custom python path for the runner.
        -- Can be a string or a list of strings.
        -- Can also be a function to return dynamic value.
        -- If not provided, the path will be inferred by checking for
        -- virtual envs in the local directory and for Pipenev/Poetry configs
        python = vim.fn.exepath "python", -- resolves from PATH at startup
      },
      -- Returns if a given file path is a test file.
      -- NB: This function is called a lot so don't perform any heavy tasks within it.
    },
  }
end

return M
