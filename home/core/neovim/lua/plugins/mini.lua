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
  -- indentscope
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
    end,
  })
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
  --  PAIRS
  --------------------------------------------------------------------------------------
  require("mini.pairs").setup(opts.pairs)

  -- If you want to disable pairs in specific prompts (like Telescope),
  -- unmap or disable for that buffer. `mini.pairs` doesn’t have per-filetype
  -- runtime options, but we can temporarily stop its mappings in that buffer.
  -- The simplest approach is to set a buffer-local flag on FileType events and
  -- clear mappings via MiniPairs.map_buf()/unmap_buf() if needed. See docs.
  -- (You can refine this later if you actually see conflicts in your setup.)
  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "TelescopePrompt" },
    callback = function()
      -- Example: unmap some common opens to avoid interference in Telescope
      local MP = _G.MiniPairs
      if MP and MP.unmap_buf then
        for _, ch in ipairs { "(", "[", "{", '"', "'" } do
          -- unmap in insert mode; second arg is pair to unregister (close char)
          -- This matches the module's buffer-unmap API in the docs.
          pcall(MP.unmap_buf, 0, "i", ch, MP.get_pairs()[ch])
        end
      end
    end,
    desc = "Reduce pairs mappings in Telescope prompt buffers",
  })
  --------------------------------------------------------------------------------------
  -- SESSIONS
  --------------------------------------------------------------------------------------

  require("mini.sessions").setup(opts.sessions)
  --------------------------------------------------------------------------------------
  -- STARTER
  --------------------------------------------------------------------------------------
  require("mini.starter").setup()
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
