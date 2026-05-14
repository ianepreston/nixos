local M = {
  {
    "<leader>db",
    function()
      require("dap").toggle_breakpoint()
    end,
    desc = "Toggle breakpoint",
  },
  {

    "<leader>dB",
    function()
      require("dap").set_breakpoint(vim.fn.input "Breakpoint condition: ")
    end,
    mode = "n",
    desc = "Condition-based breakpoint",
  },
  {

    "<leader>dc",
    function()
      require("dap").continue()
    end,
    mode = "n",
    desc = "Run/Continue",
  },
  {

    "<leader>dC",
    function()
      require("dap").run_to_cursor()
    end,
    mode = "n",
    desc = "Run to Cursor",
  },
  {

    "<leader>dk",
    function()
      require("dap").up()
    end,
    mode = "n",
    desc = "Up",
  },
  {
    "<leader>dj",
    function()
      require("dap").down()
    end,
    mode = "n",
    desc = "Down",
  },
  {
    "<leader>di",
    function()
      require("dap").step_into()
    end,
    mode = "n",
    desc = "Step Into",
  },
  {
    "<leader>do",
    function()
      require("dap").step_over()
    end,
    mode = "n",
    desc = "Step Over",
  },
  {
    "<leader>dO",
    function()
      require("dap").step_out()
    end,
    mode = "n",
    desc = "Step Out",
  },
  {
    "<leader>dp",
    function()
      require("dap").pause()
    end,
    mode = "n",
    desc = "Pause",
  },
  {
    "<leader>dr",
    function()
      require("dap").repl.toggle()
    end,
    mode = "n",
    desc = "Toggle debug REPL",
  },
  {
    "<leader>dl",
    function()
      require("dap").run_last()
    end,
    mode = "n",
    desc = "Toggle debug REPL",
  },
  {
    "<leader>ds",
    function()
      require("dap").session()
    end,
    mode = "n",
    desc = "Debugging Session",
  },
  {
    "<leader>du",
    function()
      require("dapui").toggle()
    end,
    mode = "n",
    desc = "Toggle DAP UI",
  },
  {
    "<leader>dt",
    function()
      require("dap").terminate()
    end,
    mode = "n",
    desc = "Terminate DAP",
  },
  {
    "<leader>dw",
    function()
      require("dapui.widgets").hover()
    end,
    mode = "n",
    desc = "DAP UI Widgets",
  },
  {
    "<leader>de",
    function()
      require("dapui").eval()
    end,
    mode = "n",
    desc = "DAP UI Eval",
  },
}
return M
