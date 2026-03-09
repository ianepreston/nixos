# Phase 5: Window switching

## Context

Read these files before implementing:

- `.claude/workflows.md` — decisions and target keybinding reference
- `home/darwin/hammerspoon.nix` — current alt+tab window hints picker (lines
  158-166)
- `home/optional/gnome/dconf.nix` — GNOME alt+tab config (already set to
  `switch-windows` with `current-workspace-only`)

## Prerequisites

Phases 1-4 should be complete. All workspace navigation and terminal shortcuts
should already be unified.

## Goal

Alt+tab provides sequential window cycling (current workspace/space only) on
both platforms:

- **GNOME**: Already works this way via `switch-windows` + `current-workspace-only`
- **macOS**: Replace the Hammerspoon letter-hints picker with an alt+tab window
  switcher that cycles through windows on the current space

## Implementation steps

### Step 1: Replace Hammerspoon window hints with sequential cycling

In `home/darwin/hammerspoon.nix`, replace the window picker section (currently
lines 158-166):

**Current:**
```lua
hs.hotkey.bind({"alt"}, "tab", function()
  local filter = hs.window.filter.new():setCurrentSpace(true)
  hs.hints.windowHints(filter:getWindows())
end)
```

**Replace with:**
```lua
---------------------------------------------------------------------------
-- Window cycling: alt+tab cycles through windows on the current space
-- Behaves like GNOME's alt+tab (sequential, current workspace only)
---------------------------------------------------------------------------
local function cycleWindows()
  local currentSpace = spaces.focusedSpace()
  if not currentSpace then return end

  -- Get all standard windows on the current space, ordered front-to-back
  local filter = hs.window.filter.new()
    :setCurrentSpace(true)
    :setDefaultFilter({})
  local windows = filter:getWindows(hs.window.filter.sortByFocusedLast)

  if #windows < 2 then return end

  -- Focus the next window (second in the list, since first is current)
  windows[2]:focus()
end

hs.hotkey.bind({"alt"}, "tab", cycleWindows)
```

**How this works**: `hs.window.filter` with `sortByFocusedLast` returns windows
ordered by most-recently-focused. The frontmost window is index 1, so focusing
index 2 brings the next window forward. Repeated presses cycle through the
stack.

**Limitation**: This is a simple "next window" cycle, not the full alt+tab UI
(thumbnail previews, hold-alt-and-press-tab-repeatedly). A full alt+tab
switcher with preview would require a more complex implementation using
`hs.chooser` or a third-party Hammerspoon spoon. The simple cycle should match
the user's workflow of switching between 2-3 windows on a workspace.

### Step 2: Add reverse cycling (alt+shift+tab)

Add after the alt+tab binding:

```lua
local function cycleWindowsReverse()
  local currentSpace = spaces.focusedSpace()
  if not currentSpace then return end

  local filter = hs.window.filter.new()
    :setCurrentSpace(true)
    :setDefaultFilter({})
  local windows = filter:getWindows(hs.window.filter.sortByFocusedLast)

  if #windows < 2 then return end

  -- Focus the last window in the stack (least recently focused)
  windows[#windows]:focus()
end

hs.hotkey.bind({"alt", "shift"}, "tab", cycleWindowsReverse)
```

This matches GNOME's `switch-windows-backward` bound to `<Shift><Alt>Tab`.

### Step 3: Verify GNOME alt+tab configuration

In `home/optional/gnome/dconf.nix`, confirm these settings exist (they should
already from Phase 2):

```nix
"org/gnome/desktop/wm/keybindings" = {
  switch-windows = [ "<Alt>Tab" ];
  switch-windows-backward = [ "<Shift><Alt>Tab" ];
  switch-applications = [ ];          # disabled — we use switch-windows
  switch-applications-backward = [ ]; # disabled
};

"org/gnome/shell/app-switcher" = {
  current-workspace-only = true;
};
```

**Key distinction**: `switch-windows` cycles individual windows (including
multiple windows of the same app). `switch-applications` groups windows by app.
We want `switch-windows` to match the macOS Hammerspoon behavior where each
window is a separate entry in the cycle.

### Step 4: Rebuild and test

macOS: `task build_darwin:work`
NixOS: Only needed if GNOME dconf changes were made (should be unchanged from
Phase 2).

## Validation checklist

### macOS (Hammerspoon)

- [ ] alt+tab with 2+ windows on current space: brings the next window forward
- [ ] alt+tab with only 1 window on current space: does nothing (no error)
- [ ] alt+tab repeatedly: cycles through all windows on the space
- [ ] alt+shift+tab: brings the least-recently-focused window forward (reverse)
- [ ] Windows on other spaces are NOT included in the cycle
- [ ] Minimized windows are NOT included (they're not "on" the space)
- [ ] Full-screen windows: behavior is acceptable (may not be cycleable — this
      is a known macOS limitation)

### GNOME (NixOS)

- [ ] alt+tab shows the window switcher popup (current workspace only)
- [ ] alt+shift+tab cycles backward
- [ ] Multiple windows of the same app (e.g., two Firefox windows) appear as
      separate entries, not grouped
- [ ] Windows on other workspaces are NOT shown
- [ ] `switch-applications` is disabled (no app-grouping switcher)

### Cross-platform consistency

- [ ] Same physical keys (S+Tab) cycle windows on both platforms
- [ ] Same physical keys (S+F+Tab) cycle backward on both platforms
- [ ] Both platforms show only current-workspace/space windows

### Regression checks

- [ ] cmd+tab (macOS native app switcher) still works — Hammerspoon only binds
      alt+tab, not cmd+tab
- [ ] Workspace switching (alt+h/l) still works after this change
- [ ] Window snapping (alt+arrows) still works
- [ ] No Hammerspoon errors in console after config reload
- [ ] The `hs.window.filter` doesn't cause excessive CPU usage (some filter
      configurations can be expensive — monitor Activity Monitor briefly after
      applying)

### Known limitations to accept

- [ ] macOS alt+tab doesn't show thumbnail previews like GNOME's switcher — it
      just brings the window forward immediately. This is a simpler UX but may
      feel different. Acceptable?
- [ ] If the simple cycle isn't sufficient, consider the `hs.window.switcher`
      module which provides a more visual alt+tab experience (but adds
      complexity). Document preference after testing.
