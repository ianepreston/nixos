# Implementation Plan: Unified Workflow (v2)

## Overview

Replace AeroSpace + current Hammerspoon config with native macOS window
management (Sequoia tiling + Spaces) and a slimmed-down Hammerspoon, then align
GNOME keybindings to match.

**Guiding principles** (in priority order):
1. **Consistency** — the same logical action should use the same or analogous
   physical keys where possible.
2. **Remap one platform, not both** — when platforms differ, pick one to remap
   so the same physical key works everywhere. Prefer remapping the platform
   where it's easier to do declaratively. For tab/window shortcuts,
   Hammerspoon on macOS remaps ctrl+{t,w,n} → cmd+{t,w,n} so Linux stays
   completely native. For copy/paste in Ghostty, GNOME binds super+c/v so
   macOS stays completely native.

---

## Phase 1: Remove AeroSpace

### 1a. Remove nix config references

- **`home/darwin/aerospace.nix`** — delete this file entirely. Since
  `home/darwin/default.nix` uses `customLib.scanPaths`, removing the file is
  sufficient; no import statement to update.
- **`hosts/darwin/work/homebrew.nix`** — remove `"aerospace"` from `casks` and
  `"nikitabobko/tap"` from `taps`.
- **`hosts/darwin/work/system-settings.nix`** — remove the comment referencing
  AeroSpace at the top and in the hot corners section.

### 1b. Manual cleanup after rebuild

AeroSpace may leave behind:
- Login Items entry (System Settings > General > Login Items)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)
- Preferences plist: `defaults delete bobko.aerospace 2>/dev/null`
- Since `homebrew.onActivation.cleanup = "none"`, may need manual
  `brew uninstall --cask aerospace` if nix-darwin doesn't remove it.

### 1c. Verification

- `darwin-rebuild switch` succeeds
- AeroSpace is no longer running (`pgrep -f aerospace` returns nothing)
- `~/.config/aerospace/` no longer exists (home-manager cleans it up)

---

## Phase 2: macOS — Native Spaces & Window Management

### 2a. Enable Mission Control hot corner

In `hosts/darwin/work/system-settings.nix`, update the hot corner config to use
first-class nix-darwin options:

```nix
# Move from CustomUserPreferences to first-class dock options
dock = {
  # ... existing settings ...
  wvous-tl-corner = 2;    # Mission Control
  wvous-tl-modifier = 0;  # no modifier
};
```

Remove the duplicate `CustomUserPreferences."com.apple.dock"` entries for
`wvous-tl-corner` / `wvous-tl-modifier` (keep `expose-animation-duration`
there since it has no first-class option).

### 2b. Enable ctrl+number Space switching via symbolic hotkeys

In `hosts/darwin/work/system-settings.nix`, add symbolic hotkey configuration:

```nix
system.defaults.CustomUserPreferences."com.apple.symbolichotkeys" = {
  AppleSymbolicHotKeys = {
    # Switch to Desktop 1: ctrl+1
    "118" = { enabled = true; value = { type = "standard"; parameters = [ 49 18 262144 ]; }; };
    # Switch to Desktop 2: ctrl+2
    "119" = { enabled = true; value = { type = "standard"; parameters = [ 50 19 262144 ]; }; };
    # Switch to Desktop 3: ctrl+3
    "120" = { enabled = true; value = { type = "standard"; parameters = [ 51 20 262144 ]; }; };
    # Switch to Desktop 4: ctrl+4
    "121" = { enabled = true; value = { type = "standard"; parameters = [ 52 21 262144 ]; }; };
    # Switch to Desktop 5: ctrl+5
    "122" = { enabled = true; value = { type = "standard"; parameters = [ 53 23 262144 ]; }; };

    # ctrl+left/right for workspace navigation
    # Mission Control: Move left a space (ID 79): ctrl+left
    "79" = { enabled = true; value = { type = "standard"; parameters = [ 65535 123 262144 ]; }; };
    # Mission Control: Move right a space (ID 81): ctrl+right
    "81" = { enabled = true; value = { type = "standard"; parameters = [ 65535 124 262144 ]; }; };
  };
};
```

Add activation script to apply immediately:

```nix
system.activationScripts.postActivation.text = ''
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
'';
```

**Important**: Spaces must exist first — they can't be created programmatically.
See Issues document for details.

### 2c. Rewrite Hammerspoon config

Replace the current `home/darwin/hammerspoon.nix` with a new config that handles:

1. **Window tiling with hyper key** (replaces alt+arrows):
   - `hyper+h` → left half
   - `hyper+l` → right half
   - `hyper+k` → maximize/fill
   - Keep `hyper = {"ctrl", "alt", "cmd", "shift"}` as a Lua table

2. **Alt+tab sequential window cycling** (replaces letter-hints picker):
   - Replace `hs.hints.windowHints` with sequential cycling
   - Use `hs.window.switcher` for a sequential alt+tab experience
   - Scope to current Space only

3. **Remove**:
   - alt+arrows snap bindings (replaced by hyper+hjk)
   - Workspace-related comments referencing AeroSpace

4. **Add cross-platform tab/window parity**:
   - ctrl+t → cmd+t, ctrl+w → cmd+w, ctrl+n → cmd+n via `hs.hotkey.bind`
   - This makes A+t/w/n (ctrl on Voyager) open/close tabs and windows,
     matching Linux-native ctrl+t/w/n. The native cmd+t/w/n still works too.

### 2d. macOS Ghostty keybindings

The work machine Ghostty config in `home/ian.preston/work.nix` uses a raw
`home.file` write and does **not** include keybindings. No keybinding changes
are needed — macOS Ghostty natively uses `cmd+t`/`cmd+w`/`cmd+n` for tab
management and `cmd+c`/`cmd+v` for copy/paste. The Hammerspoon ctrl→cmd remap
(from Phase 2c) also applies here, so ctrl+t/w/n works in Ghostty too.

---

## Phase 3: GNOME — Align keybindings

All changes in `home/optional/gnome/dconf.nix`.

### 3a. Workspace navigation

Replace current alt+h/l workspace switching with ctrl+arrows:

```nix
"org/gnome/desktop/wm/keybindings" = {
  switch-to-workspace-left = [ "<Ctrl>Left" ];
  switch-to-workspace-right = [ "<Ctrl>Right" ];
  move-to-workspace-left = [ "<Shift><Ctrl>Left" ];   # was <Shift><Alt>h
  move-to-workspace-right = [ "<Shift><Ctrl>Right" ];  # was <Shift><Alt>l
};
```

### 3b. Workspace switching by number

Add fixed workspaces and number-based switching:

```nix
"org/gnome/mutter" = {
  dynamic-workspaces = false;
};
"org/gnome/desktop/wm/preferences" = {
  num-workspaces = 5;
};
"org/gnome/desktop/wm/keybindings" = {
  switch-to-workspace-1 = [ "<Ctrl>1" ];
  switch-to-workspace-2 = [ "<Ctrl>2" ];
  switch-to-workspace-3 = [ "<Ctrl>3" ];
  switch-to-workspace-4 = [ "<Ctrl>4" ];
  switch-to-workspace-5 = [ "<Ctrl>5" ];
};
```

### 3c. Window tiling with hyper key

Replace alt+arrows with hyper+hjk:

```nix
"org/gnome/mutter/keybindings" = {
  toggle-tiled-left = [ "<Ctrl><Shift><Super><Alt>h" ];
  toggle-tiled-right = [ "<Ctrl><Shift><Super><Alt>l" ];
};
"org/gnome/desktop/wm/keybindings" = {
  maximize = [ "<Ctrl><Shift><Super><Alt>k" ];
};
```

### 3d. App launcher (Super+Space)

```nix
"org/gnome/mutter" = {
  overlay-key = "";  # disable bare Super opening Activities
};
"org/gnome/shell/keybindings" = {
  toggle-overview = [ "<Super>space" ];
};
```

### 3e. Mission Control equivalents

```nix
"org/gnome/desktop/interface" = {
  enable-hot-corners = true;  # top-left hot corner → Activities
};
"org/gnome/shell/keybindings" = {
  toggle-overview = [ "<Super>space" "<Ctrl>Up" ];  # both bindings
};
```

### 3f. Alt+tab window switching (keep current, verify)

Current config already has:
```nix
switch-windows = [ "<Alt>Tab" ];
switch-windows-backward = [ "<Shift><Alt>Tab" ];
```

This is already correct — `switch-windows` cycles individual windows (not
grouped by app), scoped to current workspace via the existing
`org/gnome/shell/app-switcher/current-workspace-only = true`.

### 3g. Ghostty GNOME keybindings

The existing `home/optional/gnome/ghostty.nix` has `super+c/v/t/w/n` bindings.
Refactor to use Linux-native `ctrl+` shortcuts for tab management, keeping
`super+c/v` for copy/paste (this is a one-platform remap that makes the same
physical key as macOS `cmd+c/v` work — justified since the alternative
`ctrl+shift+c/v` is significantly worse ergonomically):

```nix
keybind = [
  "super+c=copy_to_clipboard"    # D+c on Voyager, matches macOS cmd+c
  "super+v=paste_from_clipboard" # D+v on Voyager, matches macOS cmd+v
  "ctrl+t=new_tab"               # A+t on Voyager, Linux-native convention
  "ctrl+w=close_surface"         # A+w on Voyager, Linux-native convention
  "ctrl+n=new_window"            # A+n on Voyager, Linux-native convention
];
```

The `super+t/w/n` bindings are removed — tab/window management uses ctrl+t/w/n
(Linux-native) on both platforms. On macOS, Hammerspoon remaps ctrl+{t,w,n} →
cmd+{t,w,n} so the same physical key (A+t/w/n on Voyager) works everywhere.

---

## Phase 4: Cleanup & Documentation

### 4a. Update workflows.md

Rewrite `workflows.md` to reflect the new state:
- Remove all AeroSpace references
- Update the keybinding reference tables
- Document the hyper key bindings
- Note that Hammerspoon is retained but with reduced scope

### 4b. Archive workflows_update.md

Move or delete `workflows_update.md` once changes are validated.

---

## Implementation Order

1. Phase 1 (AeroSpace removal) — standalone, can be tested immediately
2. Phase 2a-2b (macOS system settings) — no dependencies
3. Phase 2c (Hammerspoon rewrite) — depends on Phase 1 being applied
4. Phase 2d (macOS Ghostty keybinds) — standalone
5. Phase 3 (GNOME changes) — fully independent of macOS phases
6. Phase 4 (docs) — after all validation

Phases 2a-2d and Phase 3 are independent and can be implemented in parallel.
Within each phase, changes are atomic — a single `darwin-rebuild switch` or
`nixos-rebuild switch` applies them.

---

## Progress Tracking

Each phase produces a `darwin-rebuild switch` or `nixos-rebuild switch` that
either succeeds or fails. Beyond build success, functional validation requires
manual testing (see testing plan).

Progress will be tracked as follows:
- Each phase has a clear "done" state (build succeeds + test cases pass)
- The testing document contains a checklist organized by phase
- After each phase, you'll run through the relevant test cases and mark
  pass/fail/notes directly in the testing document
- If a test fails, we'll document the failure in the testing doc and either
  fix it in-phase or note it as a modification needed
- If a component proves unviable (e.g., symbolic hotkeys don't apply
  correctly), the testing doc captures what happened and we'll update this
  implementation plan with the revised approach before proceeding

The testing document is the single source of truth for what works, what
doesn't, and what changed from the original plan.
