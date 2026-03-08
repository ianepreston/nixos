# Phase 1: Fix macOS workspace switching

## Context

Read these files before implementing:

- `.claude/workflows.md` — decisions and target keybinding reference
- `.claude/research.md` — full repo architecture and file locations
- `hosts/darwin/work/system-settings.nix` — current macOS system defaults
- `home/darwin/hammerspoon.nix` — current Hammerspoon config (window snapping)
- `home/darwin/aerospace.nix` — current AeroSpace config (workspace switching)

## Status

**Resolved.** Workspace switching has been moved from Hammerspoon to AeroSpace
(floating-only mode). AeroSpace uses virtual workspaces that bypass macOS Spaces
animations entirely, making switching instant. Hammerspoon is now limited to
window snapping (alt+arrows), app launching, and the window picker.

Key changes (commit `8c7705a`):

- Added `home/darwin/aerospace.nix` — floating-only mode with alt+h/l workspace
  switching, alt+shift+h/l move-and-follow, alt+1-0 direct workspace access
- Simplified `home/darwin/hammerspoon.nix` — removed all workspace switching
  code, kept window snapping, app launching, and window picker
- Updated `hosts/darwin/work/system-settings.nix` — added animation reduction
  (`NSAutomaticWindowAnimationsEnabled = false`, `expose-animation-duration`),
  hot corner (upper-left → Mission Control)
- Added `aerospace` cask to `hosts/darwin/work/homebrew.nix`

## Original problem

Workspace switching on macOS was broken and slow due to:

1. Native macOS space-switch animation (~0.3-0.5s per switch)
2. Hammerspoon's 0.35s focus delay + 0.5s debounce on top of that
3. `reduceMotion` was not enabled and caused a build error when attempted via
   `com.apple.universalaccess`

AeroSpace's virtual workspaces bypass all of this — switching is instant because
it doesn't use native macOS Spaces at all.

## Validation checklist

### Functionality

- [x] alt+h switches to the previous workspace
- [x] alt+l switches to the next workspace
- [x] alt+shift+h moves the focused window one workspace left and follows it
- [x] alt+shift+l moves the focused window one workspace right and follows it
- [x] alt+1-0 switches to specific workspaces
- [x] alt+shift+1-0 moves the focused window to a specific workspace and follows
- [x] alt+up maximizes the focused window
- [x] alt+left snaps window to left half
- [x] alt+right snaps window to right half
- [x] alt+down centers window at 70% width
- [x] Rapid alt+h or alt+l presses don't queue up or stall
- [x] Workspace switching feels instant (AeroSpace virtual workspaces)

### Regression checks

- [ ] Three-finger trackpad swipe still works for space switching
- [x] Window animations (resize, move) still feel smooth in other apps
- [x] Mission Control (ctrl+up or F3) still works
- [x] cmd+tab native app switcher still works
- [x] Hammerspoon menubar icon is present and console is accessible
- [x] Ghostty launches and works normally (alt+Return launcher still works for
      now — it gets removed in Phase 2)
- [x] Key repeat speed is unchanged (fast repeat still works in terminal/vim)
- [x] Accented character picker remains disabled (hold a key = repeat, not
      accent menu)
- [x] Hot corner upper-left triggers Mission Control / workspace overview
