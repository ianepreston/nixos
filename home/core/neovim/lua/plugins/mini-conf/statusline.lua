local M = {

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

      local function macro_indicator()
        local r = vim.fn.reg_recording()
        return (r ~= "" and (" REC @%s"):format(r)) or ""
      end
      -- Macro indicator from the event-driven provider defined in M.config()
      local macro = macro_indicator()

      return MiniStatusline.combine_groups {
        -- Left side
        { hl = mode_hl, strings = { mode } },
        { hl = "MiniStatuslineDevinfo", strings = { git, diff, diagnostics } },
        "%<", -- general truncate point on the left
        { hl = "MiniStatuslineFilename", strings = { filename } },

        -- Center/right separator
        "%=",

        -- >>> Macro component (colored like the mode for visibility)
        { hl = mode_hl, strings = { macro } },

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
}
return M
