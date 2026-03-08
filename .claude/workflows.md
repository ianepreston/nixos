# Unifying my workflows across mac and nixos

## Introduction

This is a write up coauthored by claude and me to explain what I'm trying to get
out of my workflow, and the steps I need to implement in this config to get it.

## Environment details and constraints

### Input devices and peripherals

I primarily use my work laptop closed, connected to two displays, my zsa
voyager, and a regular mouse. Touchpad specific motions or magic keyboard
function keys cannot be primary to my workflow. With that said, I do need the
system to be functional in standalone mode for if I'm using it away from my home
office.

My primary keyboard is a zsa voyager. It has multiple layers configured for
things like navigation and media playback. The primary layer is qwerty layout
with home row mods set as hold actions for ctrl, opt, cmd, shift going from left
to right on the left hand and mirrored on the right hand.

| Finger | Hold key | Modifier | macOS semantic | Linux/GNOME semantic |
| ------ | -------- | -------- | -------------- | -------------------- |
| Index  | A        | ctrl     | ctrl           | ctrl                 |
| Middle | S        | opt/alt  | alt            | alt                  |
| Ring   | D        | cmd      | cmd            | Super                |
| Pinky  | F        | shift    | shift          | shift                |

(Right hand mirrors: J=shift, K=cmd/Super, L=opt/alt, ;=ctrl)

The base layer does not include arrow keys or number keys. Including these in
keyboard workflows is acceptable, but for actions that will be frequently
performed they should be used sparingly or avoided.

### Typical workflow

I try and generally focus on a single application at a time. When multitasking
my most common workflow is to have one window on my primary monitor, and another
on my secondary, or a 50/50 split between two windows on my primary. Complicated
tiling capabilities are acceptable, but context switching between full
screen/maximized application windows should be considered the primary navigation
mechanism.

I heavily depend on keyboard driven workflows to feel productive and stay in
flow. Basic navigation between and particularly within apps should have a
keyboard first mentality.

---

## Decisions

The following decisions have been made through discussion and will guide the
implementation plan.

### Workspace navigation: standardize on alt (opt/S-key)

All workspace/window management keybindings will use **alt** as the primary
modifier on both platforms. This means changing GNOME from Super+h/l to Alt+h/l
and keeping Hammerspoon on alt+h/l. The alt modifier (middle finger, S-key on
Voyager) is less "loaded" than cmd/Super on both platforms and avoids collisions
with application-level shortcuts.

This conflicts with neovim's alt+hjkl bindings (smart-splits resize and
mini-move). Both are rarely used and will be remapped to leader-prefixed or
ctrl+alt bindings.

### Terminal: Ghostty native keybinds (no multiplexer)

Ghostty's `keybind` config will be used to set identical keybindings on both
platforms. No tmux or zellij for now. If Ghostty keybind unification proves
insufficient, zellij is the fallback.

### Copy/paste: cmd+c/v everywhere

On Linux, Ghostty will be configured to bind Super+c and Super+v (which the
Voyager sends as cmd) to copy and paste. This matches macOS native behavior and
means the same physical key combo (D+c, D+v on Voyager) works identically on
both platforms.

### Browser shortcuts: ctrl+t/w/n via Hammerspoon on macOS

Hammerspoon will remap ctrl+t, ctrl+w, and ctrl+n to their cmd equivalents
specifically when a browser (Chrome/Firefox) is focused. This way the same
physical keys work on both platforms. The only macOS conflict is that ctrl+t is
"transpose characters" in Cocoa text fields - this is a minor loss since
transpose is rarely used and the remapping is app-specific (browser only).

Ghostty will also get ctrl+t and ctrl+w bindings for tab management, keeping
terminal shortcuts consistent too.

Address bar: standardize on ctrl+l (native on both platforms).

### App launching: removed, use native launchers

Dedicated app-launch keybindings (Super+t, alt+Return, etc.) will be removed.
Use Spotlight on macOS and GNOME Activities overview on Linux instead.

### Window switching: alt+tab sequential cycling

Alt+tab will do sequential window cycling (current workspace only) on both
platforms. GNOME already does this natively. On macOS, Hammerspoon will replace
the current letter-hints picker with a sequential alt+tab window switcher.

### Neovim keybinding changes

To free up alt+hjkl for workspace management:

| Current binding | Action             | New binding         |
| --------------- | ------------------ | ------------------- |
| `<M-h/j/k/l>`  | smart-splits resize | `<leader>rh/j/k/l` |
| `<M-H/J/K/L>`  | mini-move lines     | `<C-M-h/j/k/l>`    |

### Multi-monitor: no special handling

Manual drag-and-drop for moving windows between monitors. Workspace navigation
(alt+h/l) operates on whichever monitor is currently focused.

### macOS space-switching speed

The current Hammerspoon config has two issues causing sluggish workspace
switching:

1. **Native macOS space-switch animation** (~0.3-0.5s) plays on every switch.
   "Reduce motion" is not enabled and no animation tuning is configured in
   system-settings.nix.
2. **0.35s focus delay + 0.5s debounce** in Hammerspoon code waits for the
   animation to settle.

Fix: Enable `NSGlobalDomain.NSAutomaticWindowAnimationsEnabled = false` and/or
`universalaccess.reduceMotion = true` in system-settings.nix to minimize the
animation. Then reduce the Hammerspoon timers. If native Spaces animation
remains too slow even with reduced motion, consider switching back to AeroSpace
configured in floating-only mode (its virtual workspaces bypass macOS animations
entirely).

### Ghostty config: platform-appropriate settings

Font and size differences between platforms are intentional (different display
scaling). The macOS config currently uses a raw `home.file` write rather than
the `programs.ghostty` HM module due to past issues. This can be revisited but
is low priority. The important change is adding unified `keybind` entries to
both platform configs.

---

## Unified keybinding reference

This is the target state. All bindings use the same physical keys on the
Voyager regardless of platform.

### Workspace/Window management (alt modifier = S-key)

| Action                | Binding         | Voyager keys | Notes                                |
| --------------------- | --------------- | ------------ | ------------------------------------ |
| Workspace left        | alt+h           | S+h          | GNOME dconf + Hammerspoon            |
| Workspace right       | alt+l           | S+l          | GNOME dconf + Hammerspoon            |
| Move window WS left   | alt+shift+h     | S+F+h        | GNOME dconf + Hammerspoon            |
| Move window WS right  | alt+shift+l     | S+F+l        | GNOME dconf + Hammerspoon            |
| Maximize window       | alt+up          | S+up         | GNOME dconf (or mutter) + Hammerspoon |
| Snap window left      | alt+left        | S+left       | GNOME mutter + Hammerspoon           |
| Snap window right     | alt+right       | S+right      | GNOME mutter + Hammerspoon           |
| Switch windows        | alt+tab         | S+tab        | GNOME native + Hammerspoon switcher  |

### Terminal (Ghostty keybinds, identical both platforms)

| Action     | Binding       | Voyager keys | Notes                            |
| ---------- | ------------- | ------------ | -------------------------------- |
| Copy       | cmd+c (Super) | D+c          | Native mac; Ghostty keybind linux |
| Paste      | cmd+v (Super) | D+v          | Native mac; Ghostty keybind linux |
| New tab    | ctrl+t        | A+t          | Ghostty keybind both platforms   |
| Close tab  | ctrl+w        | A+w          | Ghostty keybind both platforms   |
| New window | ctrl+n        | A+n          | Ghostty keybind both platforms   |
| Next tab   | ctrl+tab      | nav layer    | Ghostty default on linux         |
| Prev tab   | ctrl+shift+tab | nav layer   | Ghostty default on linux         |

### Browser (ctrl shortcuts unified via Hammerspoon on macOS)

| Action      | Binding       | Voyager keys | Notes                            |
| ----------- | ------------- | ------------ | -------------------------------- |
| New tab     | ctrl+t        | A+t          | Native linux; Hammerspoon remap mac |
| Close tab   | ctrl+w        | A+w          | Native linux; Hammerspoon remap mac |
| New window  | ctrl+n        | A+n          | Native linux; Hammerspoon remap mac |
| Address bar | ctrl+l        | A+l          | Native both platforms            |
| Tab cycle   | ctrl+tab      | nav layer    | Native both platforms            |

### Neovim (unchanged except freed alt bindings)

| Action              | Binding          | Notes                        |
| ------------------- | ---------------- | ---------------------------- |
| Move between splits | ctrl+h/j/k/l     | smart-splits, unchanged      |
| Resize splits       | leader+r,h/j/k/l | Moved from alt+hjkl          |
| Move lines/sel      | ctrl+alt+h/j/k/l | Moved from alt+shift+hjkl    |
| Clipboard yank      | gy / gY           | Unchanged                    |

---

## Implementation plan

### Phase 1: Fix macOS workspace switching (highest impact)

1. **system-settings.nix**: Add `reduceMotion` or animation speed settings to
   make space transitions fast
2. **hammerspoon.nix**: Reduce debounce/focus timers to match faster animations
3. **hammerspoon.nix**: Fix alt+h/l if currently broken (debug why keypresses
   aren't registering)
4. Test that workspace switching feels fast and responsive

### Phase 2: Unify workspace keybindings across platforms

5. **dconf.nix**: Change GNOME workspace nav from Super+h/l to Alt+h/l, and
   move-to-workspace from Super+Shift+h/l to Alt+Shift+h/l
6. **dconf.nix**: Change window maximize/snap from Super+arrow to Alt+arrow
7. **dconf.nix**: Remove Super+t and Super+f app launch shortcuts
8. **hammerspoon.nix**: Remove alt+Return and alt+Shift+Return app launchers
9. Test both platforms have identical workspace navigation feel

### Phase 3: Unify terminal and browser shortcuts

10. **Ghostty config (both platforms)**: Add keybinds for ctrl+t (new tab),
    ctrl+w (close tab), ctrl+n (new window)
11. **Ghostty config (linux)**: Add keybind for Super+c/Super+v to copy/paste
12. **Ghostty config (mac)**: Ensure ctrl+t/w/n work alongside native cmd
    equivalents
13. **hammerspoon.nix**: Add browser-specific ctrl+t/w/n to cmd+t/w/n remapping
14. Test terminal and browser shortcuts are consistent

### Phase 4: Fix neovim conflicts

15. **keymaps.lua**: Remap `<M-h/j/k/l>` split resize to `<leader>rh/j/k/l`
16. **keymaps.lua**: Remap `<M-H/J/K/L>` mini-move to `<C-M-h/j/k/l>`
17. Verify mini-move plugin config matches new keybindings
18. Test that neovim split resize and line movement still work

### Phase 5: Window switching

19. **hammerspoon.nix**: Replace alt+tab window hints with sequential window
    cycling (current space only)
20. Verify GNOME alt+tab behavior matches (current workspace only, all windows
    including same-app)

### Open questions (deferred, low priority)

- Can `programs.ghostty` HM module work on macOS darwin? If so, migrate the raw
  file write for config consistency.
- If macOS space animation remains too slow even with reduced motion, evaluate
  AeroSpace in floating-only mode as an alternative to Hammerspoon + native
  Spaces.
