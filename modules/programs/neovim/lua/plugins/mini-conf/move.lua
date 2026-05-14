local keymap = require "plugins.mini-conf.keymap"
local M = {
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
}
return M
