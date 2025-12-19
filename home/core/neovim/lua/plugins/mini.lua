local keymap = require "plugins.mini-conf.keymap"
local M = {
  "nvim-mini/mini.nvim",
  enabled = true,
  lazy = false,
  version = "*", -- Stable

  opts = {
    ai = require("plugins.mini-conf.ai").ai,
    indentscope = require "plugins.mini-conf.indentscope",
    files = require "plugins.mini-conf.files",
    move = require "plugins.mini-conf.move",
    sessions = require "plugins.mini-conf.sessions",
    statusline = require "plugins.mini-conf.statusline",
    surround = require "plugins.mini-conf.surround",
  },
  keys = {
    {
      "<leader>fe",
      function()
        local MiniFiles = require "mini.files"
        local path = vim.api.nvim_buf_get_name(0)

        -- If buffer has no name or the path doesn't exist, use CWD
        if path == nil or path == "" or vim.loop.fs_stat(path) == nil then
          MiniFiles.open(vim.loop.cwd(), true)
          return
        end

        -- Otherwise, open at the current file's directory
        MiniFiles.open(path, true)
      end,
      desc = "Open mini.files explorer (directory of current file)",
    },
    {
      "<leader>fE",
      function()
        require("mini.files").open(vim.loop.cwd(), true)
      end,
      desc = "Open mini.files explorer (cwd)",
    },
    -- move
    { keymap.left, mode = { "n", "x" } },
    { keymap.right, mode = { "n", "x" } },
    { keymap.down, mode = { "n", "x" } },
    { keymap.up, mode = { "n", "x" } },
  },
}

function M.init()
  -- icons
  package.preload["nvim-web-devicons"] = function()
    require("mini.icons").mock_nvim_web_devicons()
    return package.loaded["nvim-web-devicons"]
  end
  -- indentscope and pairs
  vim.api.nvim_create_autocmd("FileType", {
    -- Not all of these are filetypes, actually
    pattern = {
      "help",
      "man",
      "lspinfo",
      "nofile",
      "spectre_panel",
      "terminal",
      "telescope",
      "alpha",
      "dashboard",
      "terminal",
      "lazy",
      "mason",
      "dirvish",
      "fugitive",
      "alpha",
      "NvimTree",
      "neo-tree",
      "packer",
      "neogitstatus",
      "Trouble",
      "lir",
      "Outline",
      "spectre_panel",
      "toggleterm",
      "lazyterm",
      "DressingSelect",
      "TelescopePrompt",
    },
    callback = function()
      vim.b.miniindentscope_disable = true
      vim.b.minipairs_disable = true
    end,
  })

  -- Statusline UI
  vim.o.laststatus = 3
  vim.o.showmode = false
end
function M.config(_, opts)
  --------------------------------------------------------------------------------------
  -- AI
  --------------------------------------------------------------------------------------
  require("mini.ai").setup(opts.ai())

  -- Optional: registering text objects in which-key (Source: LazyVim)
  local objects = {
    { " ", desc = "whitespace" },
    { '"', desc = '" string' },
    { "'", desc = "' string" },
    { "(", desc = "() block" },
    { ")", desc = "() block with ws" },
    { "<", desc = "<> block" },
    { ">", desc = "<> block with ws" },
    { "?", desc = "user prompt" },
    { "U", desc = "use/call without dot" },
    { "[", desc = "[] block" },
    { "]", desc = "[] block with ws" },
    { "_", desc = "underscore" },
    { "`", desc = "` string" },
    { "a", desc = "argument" },
    { "b", desc = ")]} block" },
    { "c", desc = "class" },
    { "d", desc = "digit(s)" },
    { "e", desc = "CamelCase / snake_case" },
    { "f", desc = "function" },
    { "g", desc = "entire file" },
    { "i", desc = "indent" },
    { "o", desc = "block, conditional, loop" },
    { "q", desc = "quote `\"'" },
    { "t", desc = "tag" },
    { "u", desc = "use/call" },
    { "{", desc = "{} block" },
    { "}", desc = "{} with ws" },
  }
  local ret = { mode = { "o", "x" } }
  local mappings = vim.tbl_extend("force", {}, {
    around = "a",
    inside = "i",
    around_next = "an",
    inside_next = "in",
    around_last = "al",
    inside_last = "il",
  }, opts.mappings or {})
  mappings.goto_left = nil
  mappings.goto_right = nil

  for name, prefix in pairs(mappings) do
    name = name:gsub("^around_", ""):gsub("^inside_", "")
    ret[#ret + 1] = { prefix, group = name }
    for _, obj in ipairs(objects) do
      local desc = obj.desc
      if prefix:sub(1, 1) == "i" then
        desc = desc:gsub(" with ws", "")
      end
      ret[#ret + 1] = { prefix .. obj[1], desc = obj.desc }
    end
  end

  require("which-key").add(ret, { notify = false })
  --------------------------------------------------------------------------------------
  --  COMMENT
  --------------------------------------------------------------------------------------
  require("mini.comment").setup()
  --------------------------------------------------------------------------------------
  --  INDENTSCOPE
  --------------------------------------------------------------------------------------
  require("mini.indentscope").setup(opts.indentscope)
  --------------------------------------------------------------------------------------
  --  FILES
  --------------------------------------------------------------------------------------
  require("mini.files").setup(opts.files)
  --------------------------------------------------------------------------------------
  --  MOVE
  --------------------------------------------------------------------------------------

  require("mini.move").setup(opts.move)
  --------------------------------------------------------------------------------------
  --  NOTIFY
  --------------------------------------------------------------------------------------
  require("mini.notify").setup()

  --------------------------------------------------------------------------------------
  -- SESSIONS
  --------------------------------------------------------------------------------------

  require("mini.sessions").setup(opts.sessions)
  --------------------------------------------------------------------------------------
  --------------------------------------------------------------------------------------
  --  STATUSLINE
  --------------------------------------------------------------------------------------

  require("mini.diff").setup() -- helps statusline, not currently independently configured
  require("mini.git").setup() -- helps statusline, not currently independently configured

  vim.api.nvim_create_augroup("MiniStatuslineMacro", { clear = true })
  vim.api.nvim_create_autocmd({ "RecordingEnter", "RecordingLeave" }, {
    group = "MiniStatuslineMacro",
    callback = function(ev)
      if ev.event == "RecordingLeave" then
        -- small defer so reg_recording() is cleared before we render
        vim.defer_fn(function()
          vim.cmd "redrawstatus"
        end, 30)
      else
        vim.cmd "redrawstatus"
      end
    end,
  })

  -- Macro recording indicator state + autocmds
  -- local macro_state = { reg = "" }
  --
  -- vim.api.nvim_create_augroup("MiniStatuslineMacro", { clear = true })
  -- vim.api.nvim_create_autocmd({ "RecordingEnter", "RecordingLeave" }, {
  --   group = "MiniStatuslineMacro",
  --   callback = function(ev)
  --     if ev.event == "RecordingLeave" then
  --       -- reg_recording() clears just after the event; defer slightly to avoid stale value
  --       vim.defer_fn(function()
  --         macro_state.reg = ""
  --         vim.cmd "redrawstatus"
  --       end, 30)
  --     else
  --       macro_state.reg = vim.fn.reg_recording()
  --       vim.cmd "redrawstatus"
  --     end
  --   end,
  -- })
  --
  -- -- Expose a small provider for use inside opts.statusline.content.active
  -- local function macro_indicator()
  --   if macro_state.reg == "" then
  --     return ""
  --   end
  --   return (" REC @%s"):format(macro_state.reg)
  -- end

  require("mini.statusline").setup(opts.statusline)
  --------------------------------------------------------------------------------------
  -- SURROUND
  --------------------------------------------------------------------------------------
  require("mini.surround").setup(opts.surround)

  -- -- Map <M-e> to start surround operator, roughly mimicking "FastWrap"
  -- -- Workflow: <M-e> then type the surrounding char (like ( [ { " ' < > ), then a motion
  -- -- Examples: <M-e>(iw  or  <M-e>"ap  or  visually select then <M-e>{
  -- vim.keymap.set({ "n", "x" }, "<M-e>", function()
  --   return "ys" -- start surround operator (normal) / surround selection (visual)
  -- end, { expr = true, silent = true, desc = "Surround (wrap) like FastWrap" })
end

return M
