# Phase 3: Unify terminal and browser shortcuts

## Context

Read these files before implementing:

- `.claude/workflows.md` — decisions and target keybinding reference
- `.claude/research.md` — full repo architecture and file locations
- `home/optional/gnome/ghostty.nix` — Linux Ghostty config (programs.ghostty)
- `home/ian.preston/work.nix` — macOS Ghostty config (raw home.file write, lines
  11-19)
- `home/darwin/hammerspoon.nix` — Hammerspoon config for browser remapping

## Prerequisites

Phases 1-2 should be complete. Workspace keybindings should already be unified
on alt.

## Goal

Terminal (Ghostty) and browser shortcuts use identical physical keys on both
platforms:

- **Copy/paste in terminal**: cmd+c / cmd+v (D-key on Voyager) everywhere
- **Tab management**: ctrl+t (new), ctrl+w (close), ctrl+n (new window)
- **Browser tab management**: ctrl+t/w/n via Hammerspoon remapping on macOS

## Implementation steps

### Step 1: Add Ghostty keybinds on Linux

In `home/optional/gnome/ghostty.nix`, add keybind settings:

```nix
{
  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      theme = "Catppuccin Latte";
      font-family = "monospace";
      clipboard-read = "allow";
      clipboard-write = "allow";
      font-size = "11";

      # Unified keybindings — match macOS physical keys
      # Super+c/v for copy/paste (cmd on Voyager = Super on Linux)
      keybind = [
        "super+c=copy_to_clipboard"
        "super+v=paste_from_clipboard"
        "ctrl+t=new_tab"
        "ctrl+w=close_surface"
        "ctrl+n=new_window"
      ];
    };
  };

  home.sessionVariables = {
    TERM = "ghostty";
  };
}
```

**Important considerations**:

- `programs.ghostty.settings.keybind` may need to be a list of strings (one per
  binding) or may use a different syntax. Check the home-manager ghostty module
  to confirm the correct format. Ghostty config format uses
  `keybind = <trigger>=<action>` with one per line. In the HM module this may be
  a list attribute.
- `super+c` on Linux sends the Super (meta) modifier. On the Voyager, the D-key
  sends cmd which GNOME interprets as Super. This should map correctly.
- `ctrl+w=close_surface` closes the current tab/split. Verify this is the right
  Ghostty action name (might be `close_tab` — check Ghostty docs).
- The existing `ctrl+shift+c/v` defaults remain active alongside the new
  `super+c/v` bindings.

### Step 2: Add Ghostty keybinds on macOS

In `home/ian.preston/work.nix`, add keybinds to the raw config text:

```nix
home.file."Library/Application Support/com.mitchellh.ghostty/config" = {
  text = ''
    theme = Catppuccin Latte
    font-family = FiraCode Nerd Font Mono
    clipboard-read = allow
    clipboard-write = allow
    font-size = 14

    # Unified tab keybindings — match Linux ctrl+letter shortcuts
    keybind = ctrl+t=new_tab
    keybind = ctrl+w=close_surface
    keybind = ctrl+n=new_window
  '';
};
```

**Note**: On macOS, cmd+c/v already work natively for copy/paste in Ghostty. No
additional keybind needed for copy/paste on mac. We only need ctrl+t/w/n for tab
management consistency.

**Note**: Ghostty's raw config format uses one `keybind = ...` per line (not a
list). Each line is a separate `keybind` directive.

### Step 3: Add browser ctrl+t/w/n remapping in Hammerspoon

In `home/darwin/hammerspoon.nix`, add a browser-specific key remapping section.
This should go after the window snapping section and before the window picker:

```lua
---------------------------------------------------------------------------
-- Browser shortcut remapping: ctrl+t/w/n -> cmd+t/w/n
-- Makes browser tab shortcuts consistent with Linux (ctrl-based)
---------------------------------------------------------------------------
local browserBundleIDs = {
  ["com.google.Chrome"] = true,
  ["org.mozilla.firefox"] = true,
  ["com.apple.Safari"] = true,
}

local function isBrowserFocused()
  local app = hs.application.frontmostApplication()
  return app and browserBundleIDs[app:bundleID()] or false
end

local browserRemaps = {
  { mod = {"ctrl"}, key = "t", target_mod = {"cmd"}, target_key = "t" },
  { mod = {"ctrl"}, key = "w", target_mod = {"cmd"}, target_key = "w" },
  { mod = {"ctrl"}, key = "n", target_mod = {"cmd"}, target_key = "n" },
}

for _, remap in ipairs(browserRemaps) do
  hs.hotkey.bind(remap.mod, remap.key, function()
    if isBrowserFocused() then
      hs.eventtap.keyStroke(remap.target_mod, remap.target_key, 0)
    else
      -- Pass through: re-emit the original keystroke
      -- For non-browser apps, ctrl+t/w/n should behave normally
      hs.eventtap.keyStroke(remap.mod, remap.key, 0)
    end
  end)
end
```

**Warning about recursion**: The pass-through case (`hs.eventtap.keyStroke` with
the same modifiers) may cause infinite recursion since Hammerspoon will
re-intercept its own keystroke. Alternative approaches:

**(a) Use an eventtap instead of hotkey.bind** — this allows conditional
interception without recursion:

```lua
local browserRemap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
  local flags = event:getFlags()
  local keyCode = event:getKeyCode()

  if not flags.ctrl then return false end
  if not isBrowserFocused() then return false end

  local remaps = {
    [17] = "t",  -- keycode for 't'
    [13] = "w",  -- keycode for 'w'
    [45] = "n",  -- keycode for 'n'
  }

  if remaps[keyCode] then
    hs.eventtap.keyStroke({"cmd"}, remaps[keyCode], 0)
    return true  -- consume the original event
  end

  return false
end)
browserRemap:start()
```

This is cleaner — it only intercepts when a browser is focused and ctrl is held,
and passes through transparently otherwise. **Use this approach.**

**Verify keycodes**: The keycodes above (17=t, 13=w, 45=n) are standard macOS
virtual keycodes. Verify with `hs.keycodes.map` in the Hammerspoon console if
needed.

### Step 4: Verify ctrl+t doesn't conflict on macOS

On macOS, ctrl+t is "transpose characters" in Cocoa text fields (NSTextField,
NSTextView). The Hammerspoon eventtap approach in Step 3 only remaps when a
browser is focused, so ctrl+t in other apps (text editors, terminal) is
unaffected.

In Ghostty, the new `keybind = ctrl+t=new_tab` from Step 2 will override the
default ctrl+t behavior (which would have been passed to the shell as a control
character — `^T`, which shows process status in some shells). This is acceptable
since new-tab is more useful.

### Step 5: Rebuild and test

NixOS: `sudo nixos-rebuild switch --flake .` (or `task rebuild`) macOS:
`task build_darwin:work`

## Validation checklist

### Resolution: ctrl+t/w/n → super+t/w/n (D-key)

ctrl+letter conflicts with terminal control characters (^T, ^W, ^N). Ghostty
passes these through to the terminal despite keybind config. Solution: use the
D-key (cmd on macOS = native, Super on Linux = keybind) for tab management.
macOS cmd+t/w/n already work natively — removed redundant ctrl keybinds.

### Terminal (Ghostty) — both platforms

- [ ] super+t (D-key+t) opens a new Ghostty tab (Linux)
- [x] cmd+t (D-key+t) opens a new Ghostty tab (macOS, native default)
- [ ] super+w (D-key+w) closes the current Ghostty tab/surface (Linux)
- [x] cmd+w (D-key+w) closes the current Ghostty tab/surface (macOS, native)
- [ ] super+n (D-key+n) opens a new Ghostty window (Linux)
- [x] cmd+n (D-key+n) opens a new Ghostty window (macOS, native)
- [x] cmd+c / Super+c copies selected text in terminal (both platforms)
- [ ] cmd+v / Super+v pastes in terminal (both platforms)
- [ ] ctrl+shift+c/v still work on Linux (defaults not removed, just augmented)
- [x] ctrl+tab / ctrl+shift+tab cycle Ghostty tabs (default binding, untouched)

### Browser — macOS

- [x] ctrl+t opens a new browser tab in Chrome (Hammerspoon remap → cmd+t)
- [x] ctrl+t opens a new browser tab in Firefox (if installed)
- [x] ctrl+w closes the current browser tab
- [x] ctrl+n opens a new browser window
- [x] ctrl+l focuses the address bar (native, untouched)
- [x] ctrl+tab cycles tabs (native, untouched)
- [x] ctrl+t in non-browser apps (e.g., Ghostty, Obsidian) is NOT remapped

### Browser — Linux

- [ ] ctrl+t/w/n work as expected (native Linux browser shortcuts, unchanged)

### Regression checks

- [x] cmd+c in non-terminal apps still copies (macOS native, unaffected)
- [x] cmd+v in non-terminal apps still pastes
- [x] Ghostty theme and font are unchanged
- [ ] Ghostty clipboard read/write permissions still work
- [x] Neovim ctrl+t (tag stack) no longer conflicts — Ghostty uses super/cmd,
      not ctrl, so ctrl+t passes through to neovim normally
- [x] Shell ctrl+c (SIGINT) is unaffected — we're binding Super+c, not ctrl+c
- [x] Hammerspoon browser remapping doesn't cause typing lag
- [x] The eventtap doesn't interfere with other Hammerspoon hotkeys
