# Plan: macOS Window Management (Revised)

## Feedback applied

The previous version of this plan over-engineered the problem. It treated
cross-platform keybinding parity as a first-class design constraint, leading to
keyd translation tables, NSUserKeyEquivalents hacks, and cmd-modifier hijacking
that fought macOS at every turn. The v2 alt-modifier AeroSpace config resolved
the shortcut conflicts but introduced a tiling WM where tiling isn't wanted.

This revision starts from what's actually needed.

---

## What I actually need

Extracted from feedback at the top of this doc and the existing GNOME config:

1. **One window visible at a time, occasionally two side-by-side.** Not tiling.
   Just snap a window to left/right half when I want a split.
2. **Keyboard workspace switching** using hjkl (no arrow keys on main layer).
   Sequential prev/next is the primary navigation; numbered jump is nice to have.
3. **Move windows between workspaces** with keyboard.
4. **Launch terminal and browser** from keyboard. Everything else via Spotlight.
5. **Alt+Tab / Cmd+Tab window switching** stays native.
6. **macOS stays vanilla.** No disabling system shortcuts, no per-app
   NSUserKeyEquivalents patches. NixOS adapts to Mac, not the other way around.

### Reference: current GNOME workflow (what feels right)

```
Super+h/l          → workspace left/right
Shift+Super+h/l    → move window to workspace left/right
Super+Left/Right   → snap window to left/right half
Super+t            → terminal
Super+f            → browser
Alt+Tab            → window switching
```

Simple, no tiling, everything works.

---

## Why AeroSpace doesn't fit

AeroSpace is a tiling WM. The core of what it does (auto-arranging windows into
a tree layout) is the part I don't need. Using a tiling WM and then fighting the
tiling behavior is backwards. The alt-modifier config resolved shortcut
conflicts, but the fundamental mismatch remains: I want floating windows with
keyboard-driven workspace management, not tiling.

---

## Recommendation: Hammerspoon

**Hammerspoon** is a macOS automation framework (Lua scripting), not a window
manager. It can bind hotkeys and execute window operations without imposing any
layout model. Windows behave exactly like vanilla macOS — they stay where you put
them, they don't auto-arrange, they don't resize when you open new ones.

It can do everything needed:
- Bind alt+h/l to switch Mission Control spaces
- Bind alt+shift+h/l to move windows between spaces
- Snap windows to left/right half
- Launch apps from hotkeys
- All via a Lua config file that Nix can generate

**No SIP disable required.** Just Accessibility permission (same as AeroSpace).

### Why not other options?

| Tool | Why not |
|------|---------|
| AeroSpace | Tiling WM — the tiling is the problem |
| Yabai | Tiling WM + requires SIP disable |
| Rectangle | Window snapping only — can't switch/move between spaces with hjkl |
| Rectangle + Karabiner | Two tools doing what Hammerspoon does alone; Karabiner is heavy |
| Paneru / PaperWM.spoon | Scrolling column model — more than needed, not simpler |

---

## Keybindings

Modifier: **alt/opt** (same as current AeroSpace config, same rationale: macOS
apps rarely bind alt, so no conflicts).

### Workspace navigation

| Keys | Action | Notes |
|------|--------|-------|
| `alt+h` | Switch to space left | Sequential, like GNOME Super+h |
| `alt+l` | Switch to space right | Sequential, like GNOME Super+l |
| `alt+shift+h` | Move window to space left | Like GNOME Shift+Super+h |
| `alt+shift+l` | Move window to space right | Like GNOME Shift+Super+l |

No numbered workspaces. macOS Mission Control spaces are sequential; Hammerspoon
navigates them sequentially. This matches the GNOME workflow better than
AeroSpace's numbered model did.

### Window snapping

| Keys | Action |
|------|--------|
| `alt+left` | Snap window to left half |
| `alt+right` | Snap window to right half |
| `alt+up` | Maximize window |
| `alt+down` | Center window at reasonable size |

These use arrow keys (available on a keyboard layer) rather than hjkl because
hjkl is taken by workspace switching. Arrow-based snapping is infrequent enough
that the extra layer key is fine.

**Alternative if arrows feel too awkward:** Use `alt+shift+[` for snap left,
`alt+shift+]` for snap right, `alt+shift+\` for maximize. Can decide during
testing.

### App launching

| Keys | Action |
|------|--------|
| `alt+return` | Open Ghostty |
| `alt+shift+return` | Open Chrome |
| `cmd+space` | Spotlight (native, unchanged) |

### Everything else: native macOS

| Keys | Action | Status |
|------|--------|--------|
| `cmd+tab` | App switcher | Native, untouched |
| `cmd+h` | Hide app | Native, untouched |
| `cmd+t/w/l/r/f` | Browser/app shortcuts | Native, untouched |
| `cmd+c/v/x/z` | Clipboard | Native, untouched |
| `cmd+q` | Quit | Native, untouched |
| `cmd+,` | Preferences | Native, untouched |
| `cmd+[/]` | Browser back/forward | Native, untouched |

Zero macOS shortcuts overridden or disabled.

---

## Implementation

### Files changed

```
nixos/
├── home/
│   ├── darwin/
│   │   ├── default.nix          ← EXISTING (scanPaths importer, keep as-is)
│   │   ├── aerospace.nix        ← DELETE
│   │   └── hammerspoon.nix      ← NEW (Lua config generation)
│   └── ian.preston/
│       └── work.nix             ← NO CHANGE (already imports ../darwin)
└── hosts/
    └── darwin/
        └── work/
            ├── homebrew.nix     ← MODIFY (remove aerospace, add hammerspoon)
            └── system-settings.nix ← NO CHANGE (key repeat settings stay)
```

### `home/darwin/hammerspoon.nix`

Generates `~/.hammerspoon/init.lua` via `home.file`. The Lua config:

1. Binds alt+h/l to space left/right using `hs.spaces` + `hs.eventtap`
2. Binds alt+shift+h/l to move focused window to adjacent space
3. Binds alt+arrow keys (or alt+shift+bracket) to snap windows
4. Binds alt+return and alt+shift+return to launch apps
5. Auto-reloads config on file change

Hammerspoon space switching implementation note: `hs.spaces.moveWindowToSpace()`
+ `hs.spaces.gotoSpace()` is the standard approach. If the `hs.spaces` module
proves flaky on the current macOS version, the fallback is to use
`hs.eventtap.keyStroke` to synthesize ctrl+arrow (native Mission Control
shortcut) — less elegant but guaranteed to work.

### `hosts/darwin/work/homebrew.nix`

```nix
# Remove from taps:
"nikitabobko/tap"

# Remove from casks:
"aerospace"

# Add to casks:
"hammerspoon"
```

### Cleanup

- Delete `home/darwin/aerospace.nix`
- The `scanPaths` importer in `home/darwin/default.nix` will automatically pick
  up `hammerspoon.nix` and stop importing the deleted `aerospace.nix`

---

## Neovim: alt+hjkl conflict is gone

With this plan, only `alt+h` and `alt+l` are captured by Hammerspoon (for space
switching). `alt+j` and `alt+k` are **not bound** — they pass through to apps
normally.

This means:
- `<M-j>` and `<M-k>` in Neovim (mini.move line up/down) **work again**
- `<M-h>` and `<M-l>` are still captured — but smart-splits resize on those axes
  can use `<C-w></>` (native Vim) or a leader binding
- This is a strict improvement over AeroSpace which captured all four alt+hjkl

---

## Cross-platform alignment (future, brief)

| Action | macOS (Hammerspoon) | NixOS (GNOME or Niri) |
|--------|--------------------|-----------------------|
| Workspace left/right | alt+h/l | alt+h/l (change GNOME from Super to Alt) |
| Move window to workspace | alt+shift+h/l | alt+shift+h/l |
| Snap left/right | alt+arrows | alt+arrows (or GNOME Super+Left/Right) |
| Terminal | alt+return | alt+return |
| Window switching | cmd+tab | alt+tab |

The modifier difference (cmd+tab vs alt+tab for window switching) is the one
unavoidable platform divergence — macOS uses cmd, Linux uses alt for app
switching. Everything else can match.

NixOS details are out of scope for this plan. The point is: nothing in this
macOS config prevents alignment later.

---

## Post-deploy steps

1. Run `task build_darwin:work`
2. Open Hammerspoon, grant **Accessibility** permission
3. Hammerspoon should auto-load `~/.hammerspoon/init.lua`
4. Test: alt+h/l switches spaces, alt+shift+h/l moves windows
5. Test: alt+return opens Ghostty, alt+shift+return opens Chrome
6. Test: all cmd+* shortcuts work normally in browser and terminal
7. Remove AeroSpace from Accessibility permissions if it was granted previously

---

## What this plan intentionally omits

- Status bar / workspace indicators (Sketchybar) — not needed for core workflow
- Numbered workspace jumping — sequential nav is enough
- Tiling of any kind — windows float and stay where you put them
- keyd / cross-platform keybinding translation — NixOS adapts later, separately
- Resize modes — snap to halves covers the need; fine-grained resize isn't used
