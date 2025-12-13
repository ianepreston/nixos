-- Git decorations for buffers (highlight modified, added, and deleted lines, diff preview, etc)
-- Note: some people love inline git blame hints, some don't. Set M.opts.current_line_blame to your preferred value
-- https://github.com/lewis6991/gitsigns.nvim

local M = {
  "lewis6991/gitsigns.nvim",
  enabled = true,
  event = "BufReadPre",
  opts = {
    signs = {
      -- add = { hl = "GitSignsAdd", text = "▎", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
      -- change = { hl = "GitSignsChange", text = "▎", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
      -- delete = { hl = "GitSignsDelete", text = "▎", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
      -- topdelete = { hl = "GitSignsDelete", text = "▎", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
      -- changedelete = { hl = "GitSignsChange", text = "▎", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
    },
    on_attach = function(bufnr)
      local gs = package.loaded.gitsigns
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
      end

      -- diff
      map("n", "<leader>gd", "<cmd>Gitsigns diffthis HEAD<cr>", { desc = "Git Diff w/HEAD" })
      -- Git hunks (prev/next hunk duplicated to support two popular keybind choices)
      map("n", "<leader>ghj", function()
        require("gitsigns").next_hunk { navigation_message = false }
      end, { desc = "Next git hunk" })
      map("n", "<leader>ghk", function()
        require("gitsigns").prev_hunk { navigation_message = false }
      end, { desc = "Previous git hunk" })
      map("n", "]h", function()
        require("gitsigns").next_hunk()
      end, { desc = "Next git hunk" })
      map("n", "[h", function()
        require("gitsigns").prev_hunk()
      end, { desc = "Previous git hunk" })
      map("n", "<leader>ghp", function()
        require("gitsigns").preview_hunk()
      end, { desc = "Preview Hunk" })
      map("n", "<leader>ghr", function()
        require("gitsigns").reset_hunk()
      end, { desc = "Reset Hunk" })
      map("n", "<leader>ghR", function()
        require("gitsigns").reset_buffer()
      end, { desc = "Reset Buffer" })
      map("n", "<leader>ghs", function()
        require("gitsigns").stage_hunk()
      end, { desc = "Stage Hunk" })
      map("n", "<leader>ghu", function()
        require("gitsigns").undo_stage_hunk()
      end, { desc = "Undo Stage Hunk" })
    end,
    signcolumn = true, -- Toggle with `:Gitsigns toggle_signs`
    watch_gitdir = {
      interval = 1000,
      follow_files = true,
    },
    attach_to_untracked = true,
    current_line_blame = false, -- If false, toggle blame hints with `:Gitsigns toggle_current_line_blame`
    current_line_blame_formatter = "<author>, <author_time:%Y-%m-%d> - <summary>",
    current_line_blame_opts = {
      virt_text = true,
      virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
      delay = 1000,
    },
    sign_priority = 6,
    update_debounce = 100,
    status_formatter = nil, -- Use default
    max_file_length = 40000, -- Disable if file is longer than this (in lines)
    preview_config = {
      -- Options passed to nvim_open_win
      border = "single",
      style = "minimal",
      relative = "cursor",
      row = 0,
      col = 1,
    },
  },
}

return M
