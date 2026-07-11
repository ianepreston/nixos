-- Tree-sitter runtime activation + incremental selection.
--
-- Parsers and queries are vendored from nixpkgs (see
-- modules/programs/neovim.nix) and placed on the runtimepath via lazy's
-- `performance.rtp.paths` (lua/plugin-loader.lua). The archived
-- nvim-treesitter Lua plugin is no longer installed, so highlighting must be
-- started explicitly and incremental selection is reimplemented here on the
-- core `vim.treesitter` API.

local ts = vim.treesitter
local api = vim.api

-- Filetype -> parser-language aliases.
--
-- `vim.treesitter.start` resolves a buffer's parser from its *filetype* via
-- `vim.treesitter.language.get_lang(ft)`. When the filetype name differs from
-- the tree-sitter parser name, that lookup misses and highlighting never
-- starts. nvim-treesitter used to register these aliases; since we dropped it,
-- we register the ones our vendored parsers need. Only vendored langs whose
-- filetype != parser name belong here (identity cases like python/go/json need
-- nothing); extend this alongside `tsLangs` in modules/programs/neovim.nix when
-- a newly vendored lang has a mismatched filetype.
local ft_aliases = {
  bash = { "sh", "bash" }, -- *.sh => ft "sh"
  hcl = { "hcl", "terraform", "terraform-vars" }, -- *.tf => ft "terraform"; *.tfvars => ft "terraform-vars"
}
for lang, filetypes in pairs(ft_aliases) do
  ts.language.register(lang, filetypes)
end

-- Activate tree-sitter highlighting (and thereby foldexpr/indents) for any
-- buffer whose language has a parser on the runtimepath. Both the core langs
-- Neovim ships (c, lua, markdown, markdown_inline, query, vim, vimdoc) and the
-- nixpkgs-vendored langs resolve here; pcall swallows filetypes with no parser.
api.nvim_create_autocmd("FileType", {
  desc = "Start tree-sitter highlighting on the vendored/core parsers",
  callback = function(ev)
    pcall(ts.start, ev.buf)
  end,
})

-- Catch up buffers already loaded before this autocmd was registered (e.g. a
-- file passed on the command line, or a restored session). A no-op when the
-- FileType autocmd above already started highlighting; guards the very-first
-- buffer against any startup-ordering surprise.
for _, buf in ipairs(api.nvim_list_bufs()) do
  if api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
    pcall(ts.start, buf)
  end
end

-- Incremental selection ------------------------------------------------------
-- Reimplements nvim-treesitter.incremental_selection (removed with the plugin)
-- on the core node API. <C-space> expands the Visual selection to the next
-- larger node; <bs> shrinks it back. Move/swap motions are intentionally not
-- reimplemented.
local selection_stack = {}

-- Drop a buffer's selection stack on teardown so we don't retain stale node
-- userdata for buffers that no longer exist.
api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  desc = "Clear treesitter incremental-selection state for the buffer",
  callback = function(ev)
    selection_stack[ev.buf] = nil
  end,
})

local function same_range(a, b)
  local ar1, ac1, ar2, ac2 = a:range()
  local br1, bc1, br2, bc2 = b:range()
  return ar1 == br1 and ac1 == bc1 and ar2 == br2 and ac2 == bc2
end

-- Select a tree-sitter range (0-based, end-exclusive) as a charwise Visual
-- selection. Leaves any current Visual/Select mode first so the `v` below
-- always *enters* Visual rather than toggling it off.
local function select_node(node)
  local srow, scol, erow, ecol = node:range()
  local end_line = erow + 1
  local end_col = ecol
  if ecol == 0 then
    -- Range ends at column 0 of the next row => it spans through the end of
    -- the previous line (same adjustment mini.ai makes).
    end_line = end_line - 1
    end_col = math.max(vim.fn.col { end_line, "$" }, 1)
  end
  if vim.fn.mode() ~= "n" then
    vim.cmd "normal! \27" -- <Esc>
  end
  api.nvim_win_set_cursor(0, { srow + 1, scol })
  vim.cmd "normal! v"
  api.nvim_win_set_cursor(0, { end_line, math.max(end_col - 1, 0) })
end

local function init_selection()
  local buf = api.nvim_get_current_buf()
  local node = ts.get_node()
  if not node then
    return
  end
  selection_stack[buf] = { node }
  select_node(node)
end

local function node_incremental()
  local buf = api.nvim_get_current_buf()
  local nodes = selection_stack[buf]
  if not nodes or #nodes == 0 then
    return init_selection()
  end
  local current = nodes[#nodes]
  local parent = current:parent()
  -- Climb to the first ancestor that actually enlarges the selection.
  while parent and same_range(parent, current) do
    parent = parent:parent()
  end
  if parent then
    table.insert(nodes, parent)
    select_node(parent)
  else
    select_node(current)
  end
end

local function node_decremental()
  local buf = api.nvim_get_current_buf()
  local nodes = selection_stack[buf]
  if not nodes or #nodes <= 1 then
    if nodes and nodes[1] then
      select_node(nodes[1])
    end
    return
  end
  table.remove(nodes)
  select_node(nodes[#nodes])
end

vim.keymap.set("n", "<C-space>", init_selection, { desc = "Init treesitter selection" })
vim.keymap.set("x", "<C-space>", node_incremental, { desc = "Increment treesitter selection" })
vim.keymap.set("x", "<bs>", node_decremental, { desc = "Decrement treesitter selection" })
