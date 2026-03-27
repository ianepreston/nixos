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

| Finger | Hold key | Modifier               | macOS semantic     | Linux/GNOME semantic |
| ------ | -------- | ---------------------- | ------------------ | -------------------- |
| Index  | F        | ctrl+shift+opt/alt+cmd | ctrl+shift+opt+cmd | ctrl+shift+super+alt |
| Index  | A        | ctrl                   | ctrl               | ctrl                 |
| Middle | S        | opt/alt                | alt                | alt                  |
| Ring   | D        | cmd                    | cmd                | Super                |
| Pinky  | F        | shift                  | shift              | shift                |

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
implementation.

### Workspace management: native Spaces (macOS) / GNOME Workspaces

AeroSpace has been removed. Both platforms now use native workspace management:
- **macOS**: Native Spaces with ctrl+number (1-5) for direct access, ctrl+left/right for sequential navigation
- **GNOME**: Fixed workspaces (5) with ctrl+number and ctrl+left/right

Hammerspoon is retained with reduced scope: window tiling and alt+tab switching only.

### Window tiling: hyper key (ctrl+alt+cmd+shift)

Window tiling uses the hyper key on both platforms:
- `hyper+h` → left half
- `hyper+l` → right half
- `hyper+k` → maximize/fill

On macOS this is handled by Hammerspoon. On GNOME this is handled by dconf keybindings.

### Copy/paste: cmd+c/v everywhere

On Linux, Ghostty binds Super+c and Super+v (which the Voyager sends as cmd)
to copy and paste. This matches macOS native behavior — same physical key combo
(D+c, D+v on Voyager) works identically on both platforms.

### Browser/tab shortcuts: ctrl+t/w/n on both platforms

Hammerspoon on macOS remaps ctrl+{t,w,n} → cmd+{t,w,n}, so that ctrl+t/w/n
(A+t/w/n on Voyager) opens/closes tabs and windows on both platforms. The
native cmd+t/w/n shortcuts still work on macOS too.

- **macOS**: ctrl+t/w/n (via Hammerspoon remap to cmd+t/w/n), cmd+t/w/n also works natively
- **GNOME**: ctrl+t/w/n (native)

### Terminal tab management: ctrl+t/w/n on both platforms

Same approach — ctrl+t/w/n works on both platforms:
- **macOS Ghostty**: ctrl+t/w/n (via Hammerspoon remap), cmd+t/w/n also works natively
- **GNOME Ghostty**: ctrl+t/w/n (configured via Ghostty keybind)

### Window switching: alt+tab sequential cycling

Alt+tab does sequential window cycling (current workspace only) on both
platforms. GNOME does this natively. On macOS, Hammerspoon provides a sequential
alt+tab window switcher via `hs.window.switcher`.

### App launching: native launchers

Use Spotlight on macOS and GNOME Activities overview on Linux.
- **macOS**: Spotlight (cmd+space, native)
- **GNOME**: Activities (Super+space, hot corners)

### Mission Control / Activities overview

- **macOS**: Top-left hot corner → Mission Control
- **GNOME**: Top-left hot corner → Activities, also Super+space and ctrl+Up

---

## Unified keybinding reference

### Workspace navigation

| Action               | macOS              | GNOME              | Voyager keys |
| -------------------- | ------------------ | ------------------ | ------------ |
| Switch to space 1-5  | ctrl+1-5           | ctrl+1-5           | A+number     |
| Space left           | ctrl+left          | ctrl+left          | A+left       |
| Space right          | ctrl+right         | ctrl+right         | A+right      |
| Move window left     | —                  | ctrl+shift+left    | A+F+left     |
| Move window right    | —                  | ctrl+shift+right   | A+F+right    |
| Mission Control/Overview | hot corner (TL) | hot corner (TL) / Super+space | — |

### Window tiling

| Action    | macOS (Hammerspoon) | GNOME (dconf)              | Voyager keys |
| --------- | ------------------- | -------------------------- | ------------ |
| Left half | hyper+h             | hyper+h                    | hold ASDF+h  |
| Right half| hyper+l             | hyper+l                    | hold ASDF+l  |
| Maximize  | hyper+k             | hyper+k                    | hold ASDF+k  |

### Terminal (Ghostty)

| Action     | macOS                       | GNOME                  | Voyager keys |
| ---------- | --------------------------- | ---------------------- | ------------ |
| Copy       | cmd+c (native)              | Super+c (Ghostty bind) | D+c          |
| Paste      | cmd+v (native)              | Super+v (Ghostty bind) | D+v          |
| New tab    | ctrl+t (Hammerspoon remap)  | ctrl+t (Ghostty bind)  | A+t          |
| Close tab  | ctrl+w (Hammerspoon remap)  | ctrl+w (Ghostty bind)  | A+w          |
| New window | ctrl+n (Hammerspoon remap)  | ctrl+n (Ghostty bind)  | A+n          |

### Browser

| Action      | macOS                      | GNOME    | Voyager keys |
| ----------- | -------------------------- | -------- | ------------ |
| New tab     | ctrl+t (Hammerspoon remap) | ctrl+t   | A+t          |
| Close tab   | ctrl+w (Hammerspoon remap) | ctrl+w   | A+w          |
| New window  | ctrl+n (Hammerspoon remap) | ctrl+n   | A+n          |
| Address bar | ctrl+l (native)            | ctrl+l   | A+l          |

### Window switching

| Action           | macOS (Hammerspoon) | GNOME (native) | Voyager keys |
| ---------------- | ------------------- | -------------- | ------------ |
| Next window      | alt+tab             | alt+tab        | S+tab        |
| Previous window  | alt+shift+tab       | alt+shift+tab  | S+F+tab      |

### Neovim (unchanged)

| Action              | Binding          | Notes                     |
| ------------------- | ---------------- | ------------------------- |
| Move between splits | ctrl+h/j/k/l     | smart-splits, unchanged   |
| Resize splits       | leader+r,h/j/k/l | Moved from alt+hjkl       |
| Move lines/sel      | ctrl+alt+h/j/k/l | Moved from alt+shift+hjkl |
| Clipboard yank      | gy / gY          | Unchanged                 |
