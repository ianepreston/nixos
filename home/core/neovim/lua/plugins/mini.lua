-- Shift + Alt/Meta + Direction
local keymap = {
  left = "<M-H>",
  right = "<M-L>",
  down = "<M-J>",
  up = "<M-K>",
}
local M = {
  "nvim-mini/mini.nvim",
  enabled = true,
  lazy = false,
  version = "*", -- Stable

  opts = {
    ai = function()
      local ai = require "mini.ai"
      return {
        n_lines = 100,
        custom_textobjects = {
          o = ai.gen_spec.treesitter({
            a = { "@block.outer", "@conditional.outer", "@loop.outer" },
            i = { "@block.inner", "@conditional.inner", "@loop.inner" },
          }, {}),
          F = ai.gen_spec.treesitter({ a = "@function.outer", i = "@function.inner" }, {}),
          c = ai.gen_spec.treesitter({ a = "@class.outer", i = "@class.inner" }, {}),
        },
      }
    end,
    indentscope = {
      symbol = "│",
      options = { try_as_border = true },
    },

    files = {
      windows = {
        preview = true,
        width_focus = 30,
        width_preview = 30,
      },
      content = {
        filter = nil,
      },
      options = {
        use_as_default_explorer = true,
      },
    },
    -- Move any selection in any direction (smart: reindents vertical movements, respects v:count, etc)
    move = {
      mappings = {
        -- Move visual selection in Visual mode. Defaults are Alt (Meta) + hjkl.
        left = keymap.left,
        right = keymap.right,
        down = keymap.down,
        up = keymap.up,

        -- Move current line in Normal mode
        line_left = keymap.left,
        line_right = keymap.right,
        line_down = keymap.down,
        line_up = keymap.up,
      },

      -- Options which control moving behavior
      options = {
        -- Automatically reindent selection during linewise vertical move
        reindent_linewise = true,
      },
    },
    pairs = {
      modes = { insert = true, command = false, terminal = false },
    },
    sessions = {
      -- Whether to read latest session if Neovim opened without file arguments
      autoread = false,

      -- Whether to write current session before quitting Neovim
      autowrite = true,

      -- Directory where global sessions are stored (use `''` to disable)
      -- Note: "data" is not just XDG_DATA_HOME, see https://neovim.io/doc/user/starting.html#standard-path
      directory = vim.fn.stdpath "data" .. "/sessions/",

      -- File for local session
      -- Note: I prefer .session.vim, but some plugins (including tmux-resurrect) expect Session.vim
      file = "Session.vim",

      -- Whether to force possibly harmful actions (meaning depends on function)
      force = { read = false, write = true, delete = false },

      -- Hook functions for actions. Default `nil` means 'do nothing'.
      hooks = {
        -- Before successful action
        pre = { read = nil, write = nil, delete = nil },
        -- After successful action
        post = { read = nil, write = nil, delete = nil },
      },

      -- Whether to print session path after action
      verbose = { read = false, write = true, delete = true },
    },
    statusline = {

      use_icons = true,

      content = {
        -- Active window content (explicit, based on docs' example)
        active = function()
          local MiniStatusline = require "mini.statusline"

          -- Same sections as in docs example; adjust trunc_widths to taste
          local mode, mode_hl = MiniStatusline.section_mode { trunc_width = 120 }
          local git = MiniStatusline.section_git { trunc_width = 40 }
          local diff = MiniStatusline.section_diff { trunc_width = 75 }
          local diagnostics = MiniStatusline.section_diagnostics { trunc_width = 75 }
          local filename = MiniStatusline.section_filename { trunc_width = 140 }
          local fileinfo = MiniStatusline.section_fileinfo { trunc_width = 120 }
          local location = MiniStatusline.section_location { trunc_width = 200 }
          local search = MiniStatusline.section_searchcount { trunc_width = 75 }

          -- Macro indicator from the event-driven provider defined in M.config()
          -- local macro = (M._macro_indicator and M._macro_indicator()) or ""

          return MiniStatusline.combine_groups {
            -- Left side
            { hl = mode_hl, strings = { mode } },
            { hl = "MiniStatuslineDevinfo", strings = { git, diff, diagnostics } },
            "%<", -- general truncate point on the left
            { hl = "MiniStatuslineFilename", strings = { filename } },

            -- Center/right separator
            "%=",

            -- >>> Macro component (colored like the mode for visibility)
            -- { hl = mode_hl, strings = { macro } },

            -- Right side
            { hl = "MiniStatuslineFileinfo", strings = { fileinfo } },
            { hl = mode_hl, strings = { search, location } },
          }
        end,

        -- Inactive windows: keep the simple default pattern from docs
        inactive = function()
          local MiniStatusline = require "mini.statusline"
          local filename = MiniStatusline.section_filename { trunc_width = 140 }
          local fileinfo = MiniStatusline.section_fileinfo { trunc_width = 120 }
          return MiniStatusline.combine_groups {
            { hl = "MiniStatuslineInactive", strings = { filename } },
            "%=",
            { hl = "MiniStatuslineInactive", strings = { fileinfo } },
          }
        end,
      },
    },
    surround = {
      -- These are the default mappings, but they come with a catch: lua/plugins/flash-nvim.lua
      -- uses 's' to enter jump mode. If you delay a bit after pressing 's', you will end in
      -- a flash-nvim jump mode. To overcome this, type 'sa', 'sd' and other keybinds quickly.
      -- If you're fine with this, uncomment this block and comment alternative block
      -- mappings = {
      --   add = "sa",            -- Add surrounding in Normal and Visual modes
      --   delete = "sd",         -- Delete surrounding
      --   find = "sf",           -- Find surrounding (to the right)
      --   find_left = "sF",      -- Find surrounding (to the left)
      --   highlight = "sh",      -- Highlight surrounding
      --   replace = "sr",        -- Replace surrounding
      --   update_n_lines = "sn", -- Update `n_lines`
      --
      --   suffix_last = "l",     -- Suffix to search with "prev" method
      --   suffix_next = "n",     -- Suffix to search with "next" method
      -- },
      -- Alternative LazyVim keybinds that don't conflict with flash-nvim when typing slow
      -- Also, it enabled which-key to react properly
      mappings = {
        add = "gza", -- Add surrounding in Normal and Visual modes
        delete = "gzd", -- Delete surrounding
        find = "gzf", -- Find surrounding (to the right)
        find_left = "gzF", -- Find surrounding (to the left)
        highlight = "gzh", -- Highlight surrounding
        replace = "gzr", -- Replace surrounding
        update_n_lines = "gzn", -- Update `n_lines`

        suffix_last = "l", -- Suffix to search with "prev" method
        suffix_next = "n", -- Suffix to search with "next" method
      },
    },
  },

  keys = {
    -- files
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
  --  indentscope
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
  --  PAIRS
  --------------------------------------------------------------------------------------
  require("mini.pairs").setup(opts.pairs)

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
