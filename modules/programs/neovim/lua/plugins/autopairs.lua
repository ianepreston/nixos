-- Automatic closing of (, [, ', ", { and FastWrap mode (see below)
-- Note: it is integrated with nvim-cmp
-- https://github.com/windwp/nvim-autopairs

local M = {
  "windwp/nvim-autopairs",
  enabled = true,
  event = "InsertEnter",
  dependencies = { "hrsh7th/nvim-cmp" },
  opts = {
    check_ts = true, -- treesitter integration
    disable_filetype = { "TelescopePrompt", "dap-repl" },
    -- Don't add pairs if it already has a close pair in the same line
    enable_check_bracket_line = false,
    ts_config = {
      lua = { "string", "source" },
      javascript = { "string", "template_string" },
      java = false,
    },

    -- Before        Input                    After
    -- --------------------------------------------------
    -- (|foobar      <M-e> then press $        (|foobar)
    -- (|)(foobar)   <M-e> then press q       (|(foobar))
    fast_wrap = {
      map = "<M-e>",
      chars = { "{", "[", "(", '"', "'" },
      pattern = string.gsub([[ [%'%"%)%>%]%)%}%,] ]], "%s+", ""),
      offset = 0, -- Offset from pattern match
      end_key = "$",
      -- in <M-e> mode autopairs suggests locations for the closing bracket and marks them with these keys
      keys = "qwertyuiopzxcvbnmasdfghjkl",
      check_comma = true,
      highlight = "PmenuSel",
      highlight_grey = "LineNr",
    },
  },
}

function M.config(_, opts)
  require("nvim-autopairs").setup(opts)
  local cmp_autopairs = require "nvim-autopairs.completion.cmp"
  local cmp = require "cmp"

  local on_confirm_done = cmp_autopairs.on_confirm_done {}

  -- True when the cursor is inside a Python `import` / `from ... import` statement,
  -- where completing a callable (e.g. `datetime`) must not get `()` appended
  local function in_python_import()
    if vim.bo.filetype ~= "python" then
      return false
    end
    local ok, node = pcall(vim.treesitter.get_node, {
      pos = { vim.fn.line "." - 1, math.max(vim.fn.col "." - 2, 0) },
    })
    while ok and node do
      local t = node:type()
      if t == "import_from_statement" or t == "import_statement" then
        return true
      end
      node = node:parent()
    end
    return false
  end

  cmp.event:on("confirm_done", function(evt)
    if in_python_import() then
      return
    end
    on_confirm_done(evt)
  end)
end

return M
