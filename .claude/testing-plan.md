# Testing Plan: Unified Workflow (v2)

## How to use this document

Each phase from the implementation plan has a corresponding test section below.
After implementing a phase, run through the relevant tests manually and update
the **Result** column: `PASS`, `FAIL`, or `SKIP` (with a reason). Add notes in
the **Notes** column for anything unexpected — even if it passes.

If a test fails:
1. Document the failure details in Notes
2. If the fix is straightforward, note what was changed and re-test
3. If the fix requires a design change, add an entry to the Modifications Log
   at the bottom and flag it for plan review before continuing

This document serves as the running record of validation progress. Claude can
read it to understand current state and adjust implementation accordingly.

---

## Phase 1: AeroSpace Removal

### Build verification

| # | Test | Result | Notes |
|---|------|--------|-------|
| 1.1 | `darwin-rebuild switch` completes without errors | | |
| 1.2 | `pgrep -f aerospace` returns nothing (not running) | | |
| 1.3 | `ls ~/.config/aerospace/` — directory does not exist | | |
| 1.4 | `brew list --cask` does not include aerospace | | If still listed, run `brew uninstall --cask aerospace` manually |

### Functional verification

| # | Test | Result | Notes |
|---|------|--------|-------|
| 1.5 | Windows still appear normally on screen (no invisible/minimized windows) | | This was the core AeroSpace bug |
| 1.6 | Connecting/disconnecting from dock — windows remain visible and properly placed | | Key regression from workflows_update |
| 1.7 | Mission Control (ctrl+up or F3) shows windows normally, not tiny/scattered | | Was broken with AeroSpace |
| 1.8 | Can select windows from Mission Control with keyboard | | Was broken — test after removal |

---

## Phase 2: macOS Native Window Management

### 2a. Hot corners

| # | Test | Result | Notes |
|---|------|--------|-------|
| 2.1 | Move mouse to top-left corner — Mission Control activates | | |
| 2.2 | Other corners do nothing (no accidental triggers) | | |

### 2b. Space switching

**Pre-requisite**: Manually create 5 Spaces via Mission Control before testing.

| # | Test | Result | Notes |
|---|------|--------|-------|
| 2.3 | `ctrl+right arrow` moves to next Space | | |
| 2.4 | `ctrl+left arrow` moves to previous Space | | |
| 2.5 | `ctrl+1` switches to Space 1 | | |
| 2.6 | `ctrl+2` switches to Space 2 | | |
| 2.7 | `ctrl+3` switches to Space 3 | | |
| 2.8 | `ctrl+4` switches to Space 4 | | May need to verify keycode 21 vs 22 for '4' |
| 2.9 | `ctrl+5` switches to Space 5 | | May need to verify keycode 23 for '5' |
| 2.10 | Verify these work with the Voyager (hold A + number on nav layer) | | Ctrl = hold A on Voyager |

### 2c. Hammerspoon window management

| # | Test | Result | Notes |
|---|------|--------|-------|
| 2.11 | `hyper+h` snaps focused window to left half | | Hyper = hold F on Voyager |
| 2.12 | `hyper+l` snaps focused window to right half | | |
| 2.13 | `hyper+k` maximizes focused window | | |
| 2.14 | Window snapping works on both monitors | | |
| 2.15 | No gap between snapped windows (or acceptable gap) | | Current config has 8px gap |
| 2.16 | `alt+tab` cycles through windows sequentially (current Space only) | | |
| 2.17 | `alt+tab` does NOT show windows from other Spaces | | |
| 2.18 | `shift+alt+tab` cycles backwards | | |

### 2c-browser. Browser shortcuts (native, no remap)

Browser shortcuts use each platform's native defaults — no Hammerspoon remap.
`cmd+t`/`cmd+w`/`cmd+n` are macOS-native. `ctrl+t`/`ctrl+w`/`ctrl+n` are
GNOME-native. Different physical keys on Voyager (D+t vs A+t), but both
platform-default.

| # | Test | Result | Notes |
|---|------|--------|-------|
| 2.19 | In Chrome: `cmd+t` opens new tab (native) | | D+t on Voyager |
| 2.20 | In Chrome: `cmd+w` closes current tab (native) | | D+w on Voyager |
| 2.21 | In Chrome: `cmd+n` opens new window (native) | | D+n on Voyager |
| 2.22 | In Chrome: `ctrl+l` focuses address bar (native) | | A+l, same both platforms |
| 2.23 | In Chrome: `ctrl+tab` switches tabs (native) | | Same both platforms |
| 2.24 | `ctrl+t` in Chrome does NOT open a tab (no Hammerspoon remap) | | Confirms remap removed |
| 2.25 | `ctrl+t` in a text field transposes characters (native Cocoa behavior restored) | | Was lost under old remap |

### 2d. macOS Ghostty (native shortcuts, no custom keybinds)

| # | Test | Result | Notes |
|---|------|--------|-------|
| 2.26 | `cmd+t` opens new Ghostty tab (native) | | D+t on Voyager |
| 2.27 | `cmd+w` closes Ghostty tab/surface (native) | | D+w on Voyager |
| 2.28 | `cmd+n` opens new Ghostty window (native) | | D+n on Voyager |
| 2.29 | `cmd+c` copies in Ghostty (native) | | D+c on Voyager |
| 2.30 | `cmd+v` pastes in Ghostty (native) | | D+v on Voyager |

---

## Phase 3: GNOME Alignment

### Build verification

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.1 | `nixos-rebuild switch` (or `home-manager switch`) completes without errors | | |

### 3a. Workspace navigation

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.2 | `ctrl+right arrow` moves to next workspace | | |
| 3.3 | `ctrl+left arrow` moves to previous workspace | | |
| 3.4 | `ctrl+shift+right` moves window to next workspace | | |
| 3.5 | `ctrl+shift+left` moves window to previous workspace | | |

### 3b. Workspace by number

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.6 | Fixed 5 workspaces exist (not dynamic) | | |
| 3.7 | `ctrl+1` switches to workspace 1 | | |
| 3.8 | `ctrl+2` switches to workspace 2 | | |
| 3.9 | `ctrl+3` through `ctrl+5` work | | |

### 3c. Window tiling

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.10 | `hyper+h` tiles window to left half | | |
| 3.11 | `hyper+l` tiles window to right half | | |
| 3.12 | `hyper+k` maximizes window | | |
| 3.13 | Tiling works on both monitors | | |

### 3d-3e. App launcher & Mission Control

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.14 | Bare `Super` key does NOT open Activities | | Overlay key disabled |
| 3.15 | `Super+space` opens Activities overview | | |
| 3.16 | `ctrl+up` opens Activities overview | | |
| 3.17 | Top-left hot corner activates Activities | | |

### 3f. Window switching

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.18 | `alt+tab` cycles windows (not app groups) on current workspace | | |
| 3.19 | `shift+alt+tab` cycles backwards | | |
| 3.20 | Windows from other workspaces do NOT appear in alt+tab | | |

### 3g. Ghostty GNOME

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.21 | `super+c` copies in Ghostty | | D+c on Voyager, matches macOS cmd+c |
| 3.22 | `super+v` pastes in Ghostty | | D+v on Voyager, matches macOS cmd+v |
| 3.23 | `ctrl+t` opens new Ghostty tab | | A+t on Voyager, Linux-native convention |
| 3.24 | `ctrl+w` closes Ghostty surface | | A+w on Voyager |
| 3.25 | `ctrl+n` opens new Ghostty window | | A+n on Voyager |
| 3.26 | `super+t` does NOT open a new tab (remap removed) | | Confirms super+t/w/n dropped |

### 3h. GNOME shell keybinding conflicts

| # | Test | Result | Notes |
|---|------|--------|-------|
| 3.27 | `super+v` does NOT open notification tray | | Config moves it to super+m |
| 3.28 | `super+n` does NOT trigger focus-active-notification | | Config disables it |
| 3.29 | `ctrl+1` through `ctrl+5` don't conflict with any GNOME shortcut | | Check for unexpected behavior |

---

## Cross-Platform Parity Check

Run these after both macOS and GNOME phases are complete.

| # | Action | macOS binding | GNOME binding | Same physical keys? | Notes |
|---|--------|--------------|---------------|---------------------|-------|
| X.1 | App launcher | cmd+space (Spotlight) | super+space (Activities) | Yes (D+space) | |
| X.2 | Window cycle | alt+tab | alt+tab | Yes (S+tab) | |
| X.3 | Next workspace | ctrl+right | ctrl+right | Yes (A+right) | |
| X.4 | Prev workspace | ctrl+left | ctrl+left | Yes (A+left) | |
| X.5 | Workspace N | ctrl+N | ctrl+N | Yes (A+N) | |
| X.6 | Left half | hyper+h | hyper+h | Yes (F+h) | |
| X.7 | Right half | hyper+l | hyper+l | Yes (F+l) | |
| X.8 | Maximize | hyper+k | hyper+k | Yes (F+k) | |
| X.9 | Copy (Ghostty) | cmd+c | super+c | Yes (D+c) | One-platform remap (GNOME) |
| X.10 | Paste (Ghostty) | cmd+v | super+v | Yes (D+v) | One-platform remap (GNOME) |
| X.11 | New browser tab | cmd+t | ctrl+t | No (D+t vs A+t) | Both platform-native |
| X.12 | Close browser tab | cmd+w | ctrl+w | No (D+w vs A+w) | Both platform-native |
| X.13 | New Ghostty tab | cmd+t | ctrl+t | No (D+t vs A+t) | Both platform-native |
| X.14 | Close Ghostty tab | cmd+w | ctrl+w | No (D+w vs A+w) | Both platform-native |
| X.15 | Address bar | ctrl+l | ctrl+l | Yes (A+l) | Native both platforms |

---

## Modifications Log

Record any deviations from the implementation plan here. Each entry should note
what changed, why, and whether the implementation plan needs updating.

| Date | Phase | What changed | Why | Plan updated? |
|------|-------|-------------|-----|---------------|
| | | | | |

---

## Rollback Notes

If something goes badly wrong:
- **macOS**: AeroSpace can be reinstalled via `brew install --cask aerospace`.
  The old aerospace.toml is in git history. Hammerspoon's old config is also in
  git history.
- **GNOME**: `nixos-rebuild switch` to a previous generation, or
  `home-manager switch --flake .#<host>` to roll back dconf settings.
- Git branch strategy: implement on a feature branch so `main` stays at the
  known-good state.
