# Phase 4: Fix neovim keybinding conflicts

## Context

Read these files before implementing:

- `.claude/workflows.md` — decisions and target keybinding reference
- `home/core/neovim/lua/keymaps.lua` — main keybinding file (lines 33-44 for
  smart-splits resize, line 431 comment for mini-move)
- `home/core/neovim/lua/plugins/mini-conf/keymap.lua` — mini-move key config
- `home/core/neovim/lua/plugins/mini-conf/move.lua` — mini-move setup

## Prerequisites

Phases 1-2 should be complete. Alt+h/l are now used for workspace switching on
both platforms, which means neovim never receives `<M-h>` or `<M-l>` (they're
intercepted at the WM level). This phase formalizes the remap so the bindings
are intentional rather than silently broken.

## Goal

Move neovim's alt-based bindings to non-conflicting alternatives:

| Current           | Action              | New                  |
| ----------------- | ------------------- | -------------------- |
| `<M-h/j/k/l>`    | smart-splits resize | `<leader>rh/j/k/l`  |
| `<M-H/J/K/L>`    | mini-move lines/sel | `<C-M-h/j/k/l>`     |

## Implementation steps

### Step 1: Remap smart-splits resize in keymaps.lua

In `home/core/neovim/lua/keymaps.lua`, replace lines 33-44:

**Current:**
```lua
map("n", "<M-h>", function()
  require("smart-splits").resize_left()
end, { desc = "Grow split left" })
map("n", "<M-j>", function()
  require("smart-splits").resize_down()
end, { desc = "Grow split down" })
map("n", "<M-k>", function()
  require("smart-splits").resize_up()
end, { desc = "Grow split up" })
map("n", "<M-l>", function()
  require("smart-splits").resize_right()
end, { desc = "Grow split right" })
```

**New:**
```lua
map("n", "<leader>rh", function()
  require("smart-splits").resize_left()
end, { desc = "Grow split left" })
map("n", "<leader>rj", function()
  require("smart-splits").resize_down()
end, { desc = "Grow split down" })
map("n", "<leader>rk", function()
  require("smart-splits").resize_up()
end, { desc = "Grow split up" })
map("n", "<leader>rl", function()
  require("smart-splits").resize_right()
end, { desc = "Grow split right" })
```

### Step 2: Remap mini-move in keymap.lua

In `home/core/neovim/lua/plugins/mini-conf/keymap.lua`, change from:

```lua
local keymap = {
  left = "<M-H>",
  right = "<M-L>",
  down = "<M-J>",
  up = "<M-K>",
}
```

To:

```lua
local keymap = {
  left = "<C-M-h>",
  right = "<C-M-l>",
  down = "<C-M-j>",
  up = "<C-M-k>",
}
```

**Note on `<C-M-*>` (ctrl+alt) on terminals**: Most modern terminals (including
Ghostty) can encode ctrl+alt+letter combinations correctly via CSI u or similar
escape sequences. Ghostty uses the Kitty keyboard protocol which handles this
well. However, if ctrl+alt combos don't register in neovim, an alternative is
`<leader>mh/j/k/l` (leader+m for move).

### Step 3: Update keymaps.lua comment

In `home/core/neovim/lua/keymaps.lua`, update the mini-move comment (around
line 431):

**Current:**
```lua
-- lua/plugins/mini-move.lua
--   `<M-H>`, `<M-J>`, `<M-K>`, `<M-L>`: move selection or line with Alt/Meta + Shift + h/j/k/l
```

**New:**
```lua
-- lua/plugins/mini-move.lua (configured in mini-conf/keymap.lua)
--   `<C-M-h>`, `<C-M-j>`, `<C-M-k>`, `<C-M-l>`: move selection or line with Ctrl+Alt + h/j/k/l
```

### Step 4: Verify no other alt+hjkl references

Check that no other plugin configs reference `<M-h>`, `<M-j>`, `<M-k>`,
`<M-l>`, `<M-H>`, `<M-J>`, `<M-K>`, or `<M-L>`. The only other alt binding in
keymaps.lua is `<M-e>` for FastWrapping (autopairs) — this doesn't conflict
with workspace navigation since it's alt+e, not alt+h/l.

### Step 5: Check for leader+r conflicts

Verify that `<leader>r` isn't already used as a prefix. In keymaps.lua:
- `<leader>rf` — Spectre find & replace (line 209)
- `<leader>rb` — Spectre replace in buffer (line 212)

These use `<leader>r` as a prefix for "replace". Adding `<leader>rh/j/k/l` for
"resize" puts resize under the same prefix. This is a minor semantic mismatch
but shouldn't cause functional conflicts since `rf`, `rb` vs `rh`, `rj`, `rk`,
`rl` are all distinct.

If this feels wrong, alternatives:
- `<leader>Rh/j/k/l` (capital R for resize)
- `<C-w>+h/j/k/l` followed by a resize action (but this collides with
  split navigation)

The `<leader>r` approach is fine unless you object.

## Validation checklist

### Smart-splits resize

- [ ] In neovim with 2+ splits: `<Space>rh` resizes the split boundary left
- [ ] `<Space>rj` resizes down
- [ ] `<Space>rk` resizes up
- [ ] `<Space>rl` resizes right
- [ ] Old bindings `<M-h/j/k/l>` no longer trigger resize (they shouldn't
      reach neovim at all since the WM intercepts them)

### Mini-move

- [ ] In visual mode, select lines then `<C-M-j>` moves selection down
- [ ] `<C-M-k>` moves selection up
- [ ] `<C-M-h>` moves selection left (dedent)
- [ ] `<C-M-l>` moves selection right (indent)
- [ ] In normal mode, `<C-M-j>` moves current line down
- [ ] In normal mode, `<C-M-k>` moves current line up
- [ ] If ctrl+alt combos don't register in Ghostty, note this as a finding and
      switch to `<leader>mh/j/k/l` instead

### Regression checks

- [ ] `<C-h/j/k/l>` still navigate between splits (smart-splits move, unchanged)
- [ ] `<leader>rf` still opens Spectre find & replace
- [ ] `<leader>rb` still opens Spectre buffer replace
- [ ] `<M-e>` still triggers FastWrapping in insert mode
- [ ] Which-key (if installed) shows the new `<leader>r` bindings correctly
- [ ] `:Telescope keymaps` shows updated descriptions for resize bindings
- [ ] No "duplicate mapping" warnings on neovim startup
