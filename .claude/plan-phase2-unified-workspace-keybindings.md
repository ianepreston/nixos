# Phase 2: Unify workspace keybindings across platforms

## Context

Read these files before implementing:

- `.claude/workflows.md` — decisions and target keybinding reference
- `.claude/research.md` — full repo architecture and file locations
- `home/optional/gnome/dconf.nix` — current GNOME keybindings (lines 155-169,
  228-231, 253-270, 311-313)
- `home/darwin/hammerspoon.nix` — current Hammerspoon config
- `home/darwin/aerospace.nix` — current aerospace config

## Prerequisites

Phase 1 must be complete. macOS workspace switching should be working and fast
before changing GNOME to match.

## Goal

Both platforms use identical physical keys for workspace management. The target
modifier is **alt** (opt/S-key on Voyager) everywhere.

## Implementation steps

### Step 1: Change GNOME workspace navigation from Super to Alt

In `home/optional/gnome/dconf.nix`, modify the
`org/gnome/desktop/wm/keybindings` section (currently lines 155-169):

```nix
"org/gnome/desktop/wm/keybindings" = {
  minimize = [ ];
  move-to-monitor-down = [ ];
  move-to-monitor-left = [ ];
  move-to-monitor-right = [ ];
  move-to-monitor-up = [ ];
  move-to-workspace-left = [ "<Shift><Alt>h" ];   # was <Shift><Super>h
  move-to-workspace-right = [ "<Shift><Alt>l" ];   # was <Shift><Super>l
  switch-applications = [ ];
  switch-applications-backward = [ ];
  switch-to-workspace-left = [ "<Alt>h" ];          # was <Super>h
  switch-to-workspace-right = [ "<Alt>l" ];          # was <Super>l
  switch-windows = [ "<Alt>Tab" ];                   # unchanged
  switch-windows-backward = [ "<Shift><Alt>Tab" ];   # unchanged
};
```

### Step 2: Change GNOME window tiling from Super+arrow to Alt+arrow

In `home/optional/gnome/dconf.nix`, modify the `org/gnome/mutter/keybindings`
section (currently lines 228-231):

```nix
"org/gnome/mutter/keybindings" = {
  toggle-tiled-left = [ "<Alt>Left" ];    # was <Super>Left
  toggle-tiled-right = [ "<Alt>Right" ];  # was <Super>Right
};
```

GNOME does not have a native "maximize via keybinding" in mutter keybindings the
same way — the existing Super+Up behavior comes from the default `maximize` WM
keybinding. Add to the `wm/keybindings` section:

```nix
maximize = [ "<Alt>Up" ];    # replaces default (was unset, relied on Super+Up default)
```

### Step 3: Remove GNOME app launch shortcuts

In `home/optional/gnome/dconf.nix`, modify the media-keys sections:

Change `org/gnome/settings-daemon/plugins/media-keys` (lines 253-264):

```nix
"org/gnome/settings-daemon/plugins/media-keys" = {
  custom-keybindings = [ ];  # was [ "/org/.../custom0/" ]
  home = [ "<Super>e" ];     # keep file manager, doesn't conflict
  magnifier = [ ];
  magnifier-zoom-in = [ ];
  magnifier-zoom-out = [ ];
  screenreader = [ ];
  screensaver = [ ];
  www = [ ];                  # remove <Super>f browser launcher
};
```

Remove or empty the custom0 keybinding (lines 266-270):

```nix
"org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
  binding = "";     # was <Super>t
  command = "";     # was ghostty
  name = "";
};
```

Alternatively, remove the `custom0` section entirely if dconf allows it. If
home-manager requires the key to exist when referenced, just empty the values.

### Step 4: Remove Hammerspoon app launchers

In `home/darwin/hammerspoon.nix`, remove the app launching section (lines
144-156 in current file):

Remove these bindings:

```lua
-- alt+return: Ghostty          -- DELETE
hs.hotkey.bind({"alt"}, "return", ...)
-- alt+shift+return: Chrome     -- DELETE
hs.hotkey.bind({"alt", "shift"}, "return", ...)
```

Keep everything else (space switching, window snapping, window picker — the
picker gets replaced in Phase 5).

### Step 5: Handle GNOME Alt+h/l conflicts

Verify that `<Alt>h` and `<Alt>l` don't conflict with any other GNOME
keybinding. Known potential conflicts:

- **GNOME accessibility**: Alt is not typically used by GNOME for anything that
  would conflict. The `switch-windows` binding already uses `<Alt>Tab`.
- **Firefox/Chrome**: Alt+h/l have no default browser binding. Vimium might use
  them — check if Vimium binds `alt+h` or `alt+l` and exclude those keys in
  Vimium settings if needed.
- **Ghostty**: Alt+h/l are not bound by Ghostty by default. On Linux, the
  terminal passes alt+letter through as escape sequences to the shell/vim. This
  is fine because workspace switching happens at the WM level before the
  terminal sees the keypress.

**Important**: On GNOME, WM keybindings (like workspace switching) are handled
by Mutter before any application receives the keypress. So `<Alt>h` for
workspace-left will always take priority over any in-app alt+h binding. This
means neovim's `<M-h>` split resize will also be intercepted on Linux — which is
fine because we're remapping those in Phase 4 anyway.

### Step 6: Verify paperwm remnants

Lines 297-305 of dconf.nix contain paperwm extension settings with
`restore-keybinds` referencing `<Super>Left` and `<Super>Right`. Since we're
changing these to `<Alt>Left/Right`, either:

- Remove the paperwm sections entirely if paperwm is no longer in use
- Update the restore-keybinds to reference the new Alt bindings

Check if paperwm is in the enabled-extensions list (line 279-283) — it's NOT
listed there, so these are stale config. Remove the paperwm sections.

### Step 7: Rebuild and test

NixOS: `sudo nixos-rebuild switch --flake .` (or `task rebuild`) macOS:
`task build_darwin:work`

## Validation checklist

### GNOME (NixOS) — test on terra or luna

- [ ] Alt+h switches to workspace left
- [ ] Alt+l switches to workspace right
- [ ] Alt+Shift+h moves window to workspace left
- [ ] Alt+Shift+l moves window to workspace right
- [ ] Alt+Left tiles window to left half
- [ ] Alt+Right tiles window to right half
- [ ] Alt+Up maximizes window
- [ ] Alt+Tab cycles windows on current workspace
- [ ] Alt+Shift+Tab cycles windows backward
- [ ] Super+t no longer launches Ghostty (removed)
- [ ] Super+f no longer launches browser (removed)
- [ ] Super+e still opens file manager (kept)
- [ ] Shift+Super+s still opens screenshot UI (kept)

### macOS (Hammerspoon) — test on work machine

- [ ] alt+h switches space left (unchanged from Phase 1)
- [ ] alt+l switches space right (unchanged from Phase 1)
- [ ] alt+shift+h moves window one space left
- [ ] alt+shift+l moves window one space right
- [ ] alt+up maximizes window
- [ ] alt+left snaps left, alt+right snaps right
- [ ] alt+Return does NOT launch Ghostty (removed)
- [ ] alt+Shift+Return does NOT launch Chrome (removed)

### Cross-platform consistency

- [ ] Same physical keys (S+h, S+l) switch workspaces on both platforms
- [ ] Same physical keys (S+F+h, S+F+l) move windows between workspaces
- [ ] Same physical keys (S+arrow) snap/maximize on both platforms

### Regression checks

- [ ] GNOME Activities overview still accessible (Super key tap or hot corner)
- [ ] Browser address bar still works with Ctrl+l
- [ ] Spotlight/GNOME search still works for launching apps
- [ ] No stale dconf keys causing warnings in `journalctl --user`
- [ ] Vimium in Firefox still works for scrolling and link hints (verify alt+h/l
      don't conflict — GNOME should intercept before Firefox sees them)
- [ ] GNOME screenshot shortcut (Shift+Super+s) unchanged and working
