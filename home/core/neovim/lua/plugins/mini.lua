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
    starter = function()
      local starter = require "mini.starter"
      return {
        -- Whether to open Starter buffer on VimEnter. Not opened if Neovim was
        -- started with intent to show something else.
        autoopen = true,
        -- Whether to evaluate action of single active item
        evaluate_single = true,
        -- items = {
        --   starter.sections.telescope(),
        -- },
        content_hooks = {
          starter.gen_hook.adding_bullet(),
          starter.gen_hook.aligning("center", "center"),
        },
      }
    end,
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
    statusline = function()
      return {
        -- Pass-through options for mini.statusline.setup()
        use_icons = true,
        set_vim_settings = false, -- we'll set laststatus/showmode ourselves in M.init()

        -- Icons and symbols used by our custom sections
        diag_symbols = { error = " ", warn = " ", info = " ", hint = " " },
        ff_symbols = { unix = "", dos = "", mac = "" },

        -- Behavior toggles
        show_encoding = true, -- set to false to hide 'utf-8'
        location_fixed = true, -- true -> fixed width location to reduce jiggling
      }
    end,
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
        require("mini.files").open(vim.api.nvim_buf_get_name(0), true)
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
  -- STARTER
  --------------------------------------------------------------------------------------
  require("mini.starter").setup(opts.starter())

  --------------------------------------------------------------------------------------
  --  STATUSLINE
  --------------------------------------------------------------------------------------

  do
    local ms = require "mini.statusline"
    local sl_opts = opts.statusline()

    -- Helpers (mirroring your lualine components)
    local diag_symbols = sl_opts.diag_symbols
    local ff_symbols = sl_opts.ff_symbols

    local function diagnostics()
      local d = vim.diagnostic.get(0)
      if #d == 0 then
        return ""
      end
      local counts = { e = 0, w = 0, i = 0, h = 0 }
      for _, item in ipairs(d) do
        local s = item.severity
        if s == vim.diagnostic.severity.ERROR then
          counts.e = counts.e + 1
        end
        if s == vim.diagnostic.severity.WARN then
          counts.w = counts.w + 1
        end
        if s == vim.diagnostic.severity.INFO then
          counts.i = counts.i + 1
        end
        if s == vim.diagnostic.severity.HINT then
          counts.h = counts.h + 1
        end
      end
      local parts = {}
      if counts.e > 0 then
        table.insert(parts, diag_symbols.error .. counts.e)
      end
      if counts.w > 0 then
        table.insert(parts, diag_symbols.warn .. counts.w)
      end
      if counts.i > 0 then
        table.insert(parts, diag_symbols.info .. counts.i)
      end
      if counts.h > 0 then
        table.insert(parts, diag_symbols.hint .. counts.h)
      end
      return table.concat(parts, " ")
    end

    local function git_branch()
      local head = vim.b.gitsigns_head or vim.b.git_branch
      if not head or head == "" then
        return ""
      end
      return (" " .. head)
    end

    local function git_diff()
      local s = vim.b.gitsigns_status_dict
      if not s then
        return ""
      end
      local parts = {}
      if s.added and s.added > 0 then
        table.insert(parts, "+" .. s.added)
      end
      if s.changed and s.changed > 0 then
        table.insert(parts, "~" .. s.changed)
      end
      if s.removed and s.removed > 0 then
        table.insert(parts, "-" .. s.removed)
      end
      return table.concat(parts, " ")
    end

    local function filename()
      local name = vim.fn.expand "%:." -- relative path (like lualine path=1)
      if name == "" then
        name = "[No Name]"
      end
      return name
    end

    local function fileformat_icon()
      local ff = vim.bo.fileformat
      return ff_symbols[ff] or ff
    end

    local function shiftwidth()
      return "󰌒 " .. vim.bo.shiftwidth
    end

    local function encoding()
      local enc = vim.bo.fileencoding ~= "" and vim.bo.fileencoding or vim.o.encoding
      if not sl_opts.show_encoding and enc:lower() == "utf-8" then
        return ""
      end
      return enc
    end

    local function searchcount()
      local ok, sc = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 500 })
      if not ok or sc.total == 0 then
        return ""
      end
      return string.format(" %d/%d", sc.current, sc.total)
    end

    local function location()
      local loc
      if sl_opts.location_fixed then
        -- Fixed width to minimize jiggling
        loc = string.format("%7d/%-7d:%-3d", vim.fn.line ".", vim.fn.line "$", vim.fn.col ".")
      else
        loc = string.format("%d/%d:%d", vim.fn.line ".", vim.fn.line "$", vim.fn.col ".")
      end
      local sc = searchcount()
      return (sc ~= "" and (sc .. "  " .. loc) or loc)
    end

    local function git()
      local parts = {}
      local branch = git_branch()
      local diff = git_diff()
      if branch ~= "" then
        table.insert(parts, branch)
      end
      if diff ~= "" then
        table.insert(parts, diff)
      end
      return table.concat(parts, " ")
    end

    local function fileinfo()
      -- eol format icon, shiftwidth, encoding, filetype
      local enc = encoding()
      local ft = vim.bo.filetype ~= "" and vim.bo.filetype or "no ft"
      local parts = { fileformat_icon(), shiftwidth() }
      if enc ~= "" then
        table.insert(parts, enc)
      end
      table.insert(parts, ft)
      return table.concat(parts, " ")
    end

    local function datetime()
      return os.date "%a %m/%d %H:%M"
    end

    -- Single setup call: include `content` directly (no `set_config`)
    ms.setup {
      use_icons = sl_opts.use_icons,
      set_vim_settings = sl_opts.set_vim_settings,

      content = {
        active = function()
          return ms.combine_groups {
            -- LEFT
            { hl = "MiniStatuslineMode", strings = { ms.section_mode {} } },
            { hl = "MiniStatuslineDevinfo", strings = { git() } },

            "%<", -- (ensure it's "%<" not "%<;") truncate center

            -- CENTER
            { hl = "MiniStatuslineError", strings = { diagnostics() } },
            { hl = "MiniStatuslineFilename", strings = { filename() } },

            "%=", -- right align

            -- RIGHT
            { hl = "MiniStatuslineDevinfo", strings = { fileinfo() } },
            { hl = "MiniStatuslineFileinfo", strings = { location() } },
            { hl = "MiniStatuslineFilename", strings = { datetime() } },
          }
        end,
        inactive = function()
          return ms.default_inactive()
        end,
      },
    }
  end

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
