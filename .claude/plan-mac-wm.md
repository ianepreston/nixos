# Plan: Tiling Window Management for macOS (AeroSpace)

> **Target:** Configure the `work` nix-darwin machine with AeroSpace tiling window
> management, using keybindings designed for consistent cross-platform use with a
> ZSA Voyager and a future NixOS Hyprland setup.
>
> **Not a strict Omarchy port.** Omarchy serves as inspiration for the philosophy
> (keyboard-first, named workspaces, WM modifier) but where Omarchy conventions
> would require fighting macOS or adding compound modifiers, the Mac side wins.
> The NixOS Hyprland config (future work) will use `keyd` to bridge app-level
> shortcut differences rather than contorting Mac behaviour.

---

## Cross-Platform Design Philosophy

The ZSA Voyager has home-row mods (ctrl, option, command, shift) and **no arrow
keys on the default layer**. The same physical keyboard is used on both Mac and
NixOS. This means:

- `cmd` on Mac = `super` on NixOS → same physical key → same WM modifier on both
- All navigation uses `hjkl`, no arrow keys
- Fewer compound modifiers is better — fight macOS only when the payoff is clear

### The `super`/`cmd` vs `ctrl` Problem

Mac and NixOS use different modifiers for in-app operations:

| Action | Mac physical key | NixOS physical key |
|--------|-----------------|-------------------|
| Copy (terminal) | `super+c` (`cmd+c`) | `ctrl+shift+c` |
| Paste (terminal) | `super+v` (`cmd+v`) | `ctrl+shift+v` |
| SIGINT | `ctrl+c` | `ctrl+c` (identical ✓) |
| New tab | `super+t` (`cmd+t`) | `ctrl+t` |
| Close tab | `super+w` (`cmd+w`) | `ctrl+w` |
| Reload | `super+r` (`cmd+r`) | `ctrl+r` |

The strategy is to **bridge on the NixOS side via `keyd`**, not on the Mac side.
`keyd` intercepts specific `super+*` combos in designated app classes and
translates them to the appropriate `ctrl` or `ctrl+shift` equivalent. This means
Mac behaviour stays entirely native, and NixOS is adjusted to match it.

The specific `keyd` mappings are documented in §9 (Future NixOS work). They are
out of scope to implement now but are written out here so the Mac-side decisions
are made knowing what the NixOS side will need to do to match.

---

## 1. Tool Selection & Rationale

### Tiling Window Manager: AeroSpace

- i3/Hyprland-like tiling for macOS, tree-based layout model
- Named workspaces 1–10, same mental model as Hyprland
- Fully declarative TOML config → `xdg.configFile` in home-manager
- No SIP disabling required (unlike Yabai)
- Config at `~/.config/aerospace/aerospace.toml`
- Tap: `nikitabobko/tap`, cask: `aerospace`

### App Launcher: Spotlight

- `cmd+space` (macOS default) — same slot as Omarchy's Walker
- No installation required; built into macOS
- All per-app launching beyond terminal and browser goes through Spotlight

### Status Bar: Sketchybar — Phase 2

Waybar equivalent for macOS. AeroSpace emits workspace-change events that
Sketchybar can consume. Deferred to keep this phase scoped.

---

## 2. Modifier & Binding Strategy

**WM modifier: `cmd`** (same physical key as `super` on NixOS).

Use plain `cmd+key` wherever possible. Only one compound modifier in the whole
config: `ctrl+cmd+f` for fullscreen, kept because it is the existing macOS
fullscreen convention (what the green traffic-light button does).

### macOS System Shortcuts Disabled

Only one is disabled; everything else is left intact:

| Shortcut | Reason disabled |
|----------|----------------|
| `cmd+h` (Hide Application) | AeroSpace needs `cmd+h` for focus-left |

### macOS Shortcuts Kept Intact

| Shortcut | Meaning | Why kept |
|----------|---------|----------|
| `cmd+tab` | App switcher | Essential; no replacement |
| `cmd+t` | New tab (browser/terminal) | `super+t` on NixOS handled by keyd |
| `cmd+w` | Close tab/window | `super+w` on NixOS handled by keyd |
| `cmd+n` | New window | Common enough to keep |
| `cmd+q` | Quit app | Universal Mac convention |
| `cmd+c/v/x/z` | Clipboard / undo | Never touched |

### `cmd+l`: Taken for Navigation

`cmd+l` is assigned to AeroSpace **focus right** (the hjkl equivalent of
`Super+→`). This is a deliberate choice: consistent hjkl navigation from the
default keyboard layer matters more than preserving the browser URL bar shortcut.

The browser URL bar shortcut is replaced with **`ctrl+l`**, which:
- Works natively in Firefox on NixOS/Linux (no changes needed)
- Is configured declaratively for Chrome on macOS via `NSUserKeyEquivalents` in
  `system-settings.nix` (maps Chrome's "Open Location..." menu item to `ctrl+l`)

This gives a **unified physical key for URL bar access on both platforms**: press
ctrl (home-row) + l.

### Accepted Tradeoffs

| Lost shortcut | What replaces it |
|--------------|-----------------|
| `cmd+l` browser URL bar | `ctrl+l` (configured on both platforms) |
| `cmd+h` Hide Application | Rarely used; disabled |
| `cmd+[`/`cmd+]` browser back/forward | Trackpad gesture or mouse |
| `cmd+1`–`9` browser/app tab numbers | Workspace switching takes priority |

---

## 3. Keybinding Map

All navigation uses `hjkl` — no arrow keys.

### Window Focus

| Keys | Action | Notes |
|------|--------|-------|
| `cmd-h` | `focus left` | Replaces Hide (disabled) |
| `cmd-j` | `focus down` | No conflict |
| `cmd-k` | `focus up` | No conflict |
| `cmd-l` | `focus right` | Replaces browser URL bar; use `ctrl+l` for URL bar |

### Window Movement

| Keys | Action | Notes |
|------|--------|-------|
| `cmd-shift-h` | `move left` | No conflict |
| `cmd-shift-j` | `move down` | No conflict |
| `cmd-shift-k` | `move up` | No conflict |
| `cmd-shift-l` | `move right` | No conflict |

### Workspace Switching

| Keys | Action | Notes |
|------|--------|-------|
| `cmd-1` – `cmd-0` | `workspace 1` – `workspace 10` | Replaces browser tab numbers |
| `cmd-shift-1` – `cmd-shift-0` | `move-node-to-workspace 1` – `10` | No conflict |
| `cmd-[` | `workspace prev` | Loses browser back; use trackpad |
| `cmd-]` | `workspace next` | Loses browser forward; use trackpad |
| `cmd-backslash` | `workspace-back-and-forth` | Rare conflict |

### Window Layout

| Keys | Action | Notes |
|------|--------|-------|
| `ctrl-cmd-f` | `fullscreen` | macOS fullscreen convention; one compound modifier |
| `cmd-shift-space` | `layout floating tiling` | Toggle float |
| `cmd-comma` | `layout h_tiles v_tiles` | Toggle split direction; may revisit if preferences conflict |
| `cmd-r` | enter `resize` mode | — |

### Resize Mode (modal)

Enter via `cmd-r`. Plain `hjkl` inside the mode — no modifier needed.

| Key | Action |
|-----|--------|
| `h` | `resize width -50` |
| `l` | `resize width +50` |
| `j` | `resize height +50` |
| `k` | `resize height -50` |
| `enter` / `esc` | return to main mode |

### Application Launching

Only terminal and browser are given direct shortcuts. Everything else is launched
via Spotlight (`cmd+space`).

| Keys | Action |
|------|--------|
| `cmd-space` | Spotlight |
| `cmd-return` | Ghostty terminal |
| `cmd-shift-return` | Chrome (browser) |

---

## 4. Browser & Terminal Consistency (Cross-Platform)

This section maps every relevant in-app operation to a physical key combination,
showing how Mac (native) and NixOS (via keyd, future) produce consistent
behaviour from the same physical keystrokes.

### Browser (Chrome on Mac, Firefox on NixOS)

| Operation | Physical keys | Mac result | NixOS result (via keyd) |
|-----------|--------------|-----------|------------------------|
| New tab | `super+t` | `cmd+t` → new tab (native) | keyd: `ctrl+t` → new tab (native) |
| Close tab | `super+w` | `cmd+w` → close tab (native) | keyd: `ctrl+w` → close tab (native) |
| Reopen closed tab | `super+shift+t` | `cmd+shift+t` → reopen (native) | keyd: `ctrl+shift+t` → reopen (native) |
| Next tab | `ctrl+tab` | `ctrl+tab` → next tab (native in Chrome) | `ctrl+tab` → next tab (native in Firefox) |
| Prev tab | `ctrl+shift+tab` | `ctrl+shift+tab` → prev tab (native) | `ctrl+shift+tab` → prev tab (native) |
| URL bar | `ctrl+l` | `ctrl+l` → Chrome "Open Location..." (via NSUserKeyEquivalents) | `ctrl+l` → URL bar (native in Firefox) |
| Reload | `super+r` | `cmd+r` → reload (native) | keyd: `ctrl+r` → reload (native) |
| Find in page | `super+f` | `cmd+f` → find (native) | keyd: `ctrl+f` → find (native) |

**Tab cycling uses `ctrl+tab`** — this is already native in both Chrome and Firefox
on both platforms. No changes needed. Physical key: ctrl (home-row) + tab.

**URL bar uses `ctrl+l`** — native in Firefox; configured for Chrome on Mac via
`system-settings.nix`. Physical key: ctrl (home-row) + l.

### Terminal (Ghostty on both platforms)

The Mac side is straightforward — Ghostty on Mac follows macOS conventions
natively. The NixOS side requires both `keyd` and a small set of explicit Ghostty
keybind overrides to make `ctrl+*` (without shift) work for tab operations.

| Operation | Physical keys | Mac result | NixOS result |
|-----------|--------------|-----------|-------------|
| New tab | `super+t` | `cmd+t` → new tab (Ghostty native) | keyd: `ctrl+t` → new tab (Ghostty config: `ctrl+t=new_tab`) |
| Close tab | `super+w` | `cmd+w` → close tab (Ghostty native) | keyd: `ctrl+w` → close surface (Ghostty config: `ctrl+w=close_surface`) |
| Next tab | `ctrl+tab` | `ctrl+tab` → next tab (Ghostty config: `ctrl+tab=next_tab`) | `ctrl+tab` → next tab (Ghostty config: `ctrl+tab=next_tab`) |
| Prev tab | `ctrl+shift+tab` | `ctrl+shift+tab` → prev tab (Ghostty config) | `ctrl+shift+tab` → prev tab (Ghostty config) |
| Copy text | `super+c` | `cmd+c` → copy (Ghostty native) | keyd: `ctrl+shift+c` → copy (terminal convention) |
| Paste | `super+v` | `cmd+v` → paste (Ghostty native) | keyd: `ctrl+shift+v` → paste (terminal convention) |
| SIGINT | `ctrl+c` | `ctrl+c` → SIGINT (identical, native) | `ctrl+c` → SIGINT (identical, native) |

**Note on SIGINT:** `ctrl+c` sends SIGINT on both platforms using the same physical
ctrl (home-row) key. No keyd involvement needed for this.

**Note on copy/paste in terminal:** The physical key for copy/paste in terminal is
`super+c/v` on both platforms. On Mac, Ghostty translates this to `cmd+c/v` (copy
to clipboard). On NixOS, keyd translates `super+c/v` → `ctrl+shift+c/v` (the Linux
terminal clipboard convention). The physical action feels the same; the underlying
OS signals differ.

**Note on `ctrl+t` vs `ctrl+shift+t` in Ghostty on Linux:** Ghostty's default Linux
keybinding for new tab is `ctrl+shift+t`. The NixOS Ghostty config must explicitly
add `ctrl+t=new_tab` to align with the keyd translation. This is a deliberate
Ghostty config choice, not a keyd limitation.

### Ghostty Keybinding Changes (Relevant to This Phase)

The Mac-side Ghostty config lives in `home/ian.preston/work.nix` (via
`xdg.configFile."ghostty/config"`). The following lines need to be added to make
tab cycling consistent with the cross-platform model defined above:

```
keybind = cmd+t=new_tab
keybind = ctrl+tab=next_tab
keybind = ctrl+shift+tab=previous_tab
```

`cmd+t=new_tab` is required: without it, `cmd+t` triggers macOS native
`NSWindowTabBar` which creates a separate `NSWindow` per tab. AeroSpace tiles
each `NSWindow` independently, causing window resizing and left/right position
switching when cycling tabs. Binding `new_tab` keeps all tabs inside one window.

The other two work on Mac Ghostty today (no keyd needed) and will be mirrored on
the NixOS Ghostty config when that is built.

---

## 5. Repository Architecture

Follows existing patterns in `.claude/research.md`.

### New Directory: `home/darwin/`

Mirrors `home/ipreston/gnome/` — platform-level optional module directory for
darwin. The `scanPaths` auto-importer means any `.nix` file added here is
automatically included.

### File Tree of All Changes

```
nixos/
├── home/
│   ├── darwin/                          ← NEW
│   │   ├── default.nix                  ← NEW (scanPaths importer)
│   │   └── aerospace.nix               ← NEW (AeroSpace TOML config)
│   └── ian.preston/
│       └── work.nix                     ← MODIFIED (import ../darwin; Ghostty keybinds)
└── hosts/
    └── darwin/
        └── work/
            ├── default.nix              ← MODIFIED (import system-settings.nix)
            ├── homebrew.nix             ← MODIFIED (add tap, aerospace)
            └── system-settings.nix     ← NEW (key repeat; disable cmd+h, cmd+space; ctrl+l for Chrome)
```

---

## 6. Detailed File Specifications

### `home/darwin/default.nix`

```nix
{ customLib, ... }:
{
  imports = customLib.scanPaths ./.;
}
```

### `home/darwin/aerospace.nix`

```nix
{ ... }:
{
  xdg.configFile."aerospace/aerospace.toml".text = ''
    start-at-login = true

    default-root-container-layout = 'tiles'
    default-root-container-orientation = 'auto'

    [gaps]
    inner.horizontal = 5
    inner.vertical   = 5
    outer.left       = 10
    outer.bottom     = 10
    outer.top        = 10
    outer.right      = 10

    accordion-padding = 30

    [mode.main.binding]

    # Window focus (hjkl)
    cmd-h = 'focus left'
    cmd-j = 'focus down'
    cmd-k = 'focus up'
    cmd-l = 'focus right'

    # Window movement
    cmd-shift-h = 'move left'
    cmd-shift-j = 'move down'
    cmd-shift-k = 'move up'
    cmd-shift-l = 'move right'

    # Workspace switching
    cmd-1 = 'workspace 1'
    cmd-2 = 'workspace 2'
    cmd-3 = 'workspace 3'
    cmd-4 = 'workspace 4'
    cmd-5 = 'workspace 5'
    cmd-6 = 'workspace 6'
    cmd-7 = 'workspace 7'
    cmd-8 = 'workspace 8'
    cmd-9 = 'workspace 9'
    cmd-0 = 'workspace 10'

    cmd-shift-1 = 'move-node-to-workspace 1'
    cmd-shift-2 = 'move-node-to-workspace 2'
    cmd-shift-3 = 'move-node-to-workspace 3'
    cmd-shift-4 = 'move-node-to-workspace 4'
    cmd-shift-5 = 'move-node-to-workspace 5'
    cmd-shift-6 = 'move-node-to-workspace 6'
    cmd-shift-7 = 'move-node-to-workspace 7'
    cmd-shift-8 = 'move-node-to-workspace 8'
    cmd-shift-9 = 'move-node-to-workspace 9'
    cmd-shift-0 = 'move-node-to-workspace 10'

    # Workspace cycling
    cmd-leftSquareBracket  = 'workspace prev'
    cmd-rightSquareBracket = 'workspace next'
    cmd-backslash          = 'workspace-back-and-forth'

    # Layout
    ctrl-cmd-f      = 'fullscreen'
    cmd-shift-space = 'layout floating tiling'
    cmd-comma       = 'layout h_tiles v_tiles'

    # Resize mode
    cmd-r = 'mode resize'

    # App launching (terminal and browser only; everything else via Spotlight)
    cmd-return       = "exec-and-forget open -a Ghostty"
    cmd-shift-return = "exec-and-forget open -a 'Google Chrome'"

    [mode.resize.binding]
    h     = 'resize width -50'
    l     = 'resize width +50'
    j     = 'resize height +50'
    k     = 'resize height -50'
    enter = 'mode main'
    esc   = 'mode main'
  '';
}
```

### `home/ian.preston/work.nix` (changes)

Two changes:
1. Add `../darwin` to imports
2. Add Ghostty keybindings for cross-platform tab cycling

```nix
imports = [
  ../core/default.nix
  ../darwin
];
```

In the `xdg.configFile."ghostty/config"` text block, append:

```
keybind = ctrl+tab=next_tab
keybind = ctrl+shift+tab=previous_tab
```

### `hosts/darwin/work/system-settings.nix`

```nix
{ ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      # Fast key repeat for hjkl navigation
      KeyRepeat = 2;
      InitialKeyRepeat = 15;
      ApplePressAndHoldEnabled = false;
    };

    # Per-app menu shortcut: ctrl+l → "Open Location..." in Chrome.
    # This provides a unified URL-bar shortcut: ctrl+l on both Mac (Chrome)
    # and NixOS (Firefox, where ctrl+l is native). cmd+l is taken by AeroSpace.
    CustomUserPreferences = {
      "com.google.Chrome" = {
        NSUserKeyEquivalents = {
          "Open Location..." = "^l"; # ^ = ctrl
        };
      };

      # Disable the macOS system shortcut that conflicts with AeroSpace.
      #
      # Symbolic hotkey ID:
      #   12 = Hide application (cmd+h) — AeroSpace focus-left
      #
      # cmd+space (Spotlight, ID 64) is left enabled — Spotlight is the app
      # launcher. Changes require a logout/login to take effect.
      "com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys = {
          "12" = {
            enabled = false;
            value = { parameters = [ 104 4 1048576 ]; type = "standard"; };
          };
        };
      };
    };
  };
}
```

### `hosts/darwin/work/homebrew.nix` (changes)

Add to `taps`:
```nix
"nikitabobko/tap"
```

Add to `casks`:
```nix
"nikitabobko/tap/aerospace"
```

### `hosts/darwin/work/default.nix` (change)

Add `./system-settings.nix` to imports alongside `./homebrew.nix`.

---

## 7. Post-Deploy Manual Steps

### AeroSpace (one-time)
1. AeroSpace auto-starts at login after first grant
2. Grant **Accessibility** permission when prompted (**System Settings → Privacy
   & Security → Accessibility**)

### Session restart
Log out and back in after the first `darwin-rebuild switch` to flush the
WindowServer shortcut cache (the `cmd+h` and `cmd+space` disable changes require
this).

---

## 8. Multi-Monitor Notes

Workspaces 1–7 are pinned to `'main'`, workspaces 8–10 to `'secondary'`.
Using `'main'`/`'secondary'` (not monitor names) means standalone-laptop mode
works without modification — AeroSpace simply puts all workspaces on `'main'`
when no secondary monitor is present.

```toml
[workspace-to-monitor-force-assignment]
1 = 'main'
2 = 'main'
3 = 'main'
4 = 'main'
5 = 'main'
6 = 'main'
7 = 'main'
8 = 'secondary'
9 = 'secondary'
10 = 'secondary'
```

---

## 9. NixOS Hyprland / keyd Companion Config (Future, Out of Scope)

Written here so the Mac decisions are grounded in the full cross-platform picture.
None of this is implemented now.

### keyd config (NixOS)

`keyd` intercepts specific `super+*` combos in designated application classes and
translates them. The translation table below is what enables the cross-platform
consistency described in §4.

**In browser windows (Firefox):**

| Physical key | keyd sends | Result |
|-------------|-----------|--------|
| `super+t` | `ctrl+t` | new tab |
| `super+w` | `ctrl+w` | close tab |
| `super+shift+t` | `ctrl+shift+t` | reopen tab |
| `super+r` | `ctrl+r` | reload |
| `super+f` | `ctrl+f` | find in page |
| `super+l` | `ctrl+l` | URL bar (native in Firefox) |

*Note: `super+l` is only sent through as `ctrl+l` in the browser, not in other
apps. In other contexts, `super+l` reaches Hyprland as `super+l` = focus right.*

**In terminal windows (Ghostty on NixOS):**

| Physical key | keyd sends | Result |
|-------------|-----------|--------|
| `super+c` | `ctrl+shift+c` | copy (terminal clipboard convention) |
| `super+v` | `ctrl+shift+v` | paste |
| `super+t` | `ctrl+t` | new tab (Ghostty config: `ctrl+t=new_tab`) |
| `super+w` | `ctrl+w` | close tab (Ghostty config: `ctrl+w=close_surface`) |

*Note: `ctrl+c` for SIGINT is identical on both platforms (same physical ctrl
home-row key) and requires no keyd translation.*

**All other `super+*` combos** (e.g. `super+h/j/k/l` for WM focus, `super+1-0`
for workspaces) are **not listed in keyd** for these app classes. They pass
through to Hyprland as `super+*` and trigger WM actions — same as AeroSpace
intercepts them globally on Mac.

### Ghostty NixOS config additions

```
keybind = ctrl+t=new_tab
keybind = ctrl+w=close_surface
keybind = ctrl+tab=next_tab
keybind = ctrl+shift+tab=previous_tab
```

These override Ghostty's default Linux keybindings (which use `ctrl+shift+t` for
new tab) to match what keyd is sending.

### Hyprland WM bindings (NixOS)

Mirror the AeroSpace bindings exactly, substituting `super` for `cmd`:

```
super + h/j/k/l          → focus left/down/up/right
super + shift + h/j/k/l  → move window
super + 1-0              → workspace 1-10
super + shift + 1-0      → move to workspace 1-10
super + [/]              → workspace prev/next
super + \                → workspace back-and-forth
ctrl  + super + f        → fullscreen
super + shift + space    → toggle floating
super + comma            → toggle split
super + r                → resize mode
super + return           → launch Ghostty
super + shift + return   → launch Firefox
```

The physical chords are identical to the Mac AeroSpace bindings. No mental model
switch between platforms.

---

## 10. Implementation Order

1. `home/darwin/default.nix` — create scanPaths importer
2. `home/darwin/aerospace.nix` — create AeroSpace config module
3. `hosts/darwin/work/system-settings.nix` — create system settings module
4. `hosts/darwin/work/homebrew.nix` — add `nikitabobko/tap` + `aerospace`
5. `hosts/darwin/work/default.nix` — import `system-settings.nix`
6. `home/ian.preston/work.nix` — import `../darwin`; add Ghostty tab keybinds
7. Run `task build_darwin:work`
8. Manual: AeroSpace Accessibility grant
9. Log out / log in
10. Test bindings against §3 table; verify `ctrl+l` opens Chrome URL bar

---

## 11. Known Gaps vs. Omarchy Reference

| Omarchy Feature | Mac Implementation | Gap |
|----------------|-------------------|-----|
| Walker app launcher | Spotlight | Different UI, same binding |
| Waybar status bar | macOS menu bar | No equivalent this phase |
| `Super+Tab` workspace cycle | `cmd+[` / `cmd+]` | Different keys; no arrows available |
| `Super+F` fullscreen | `ctrl+cmd+f` | Compound modifier (macOS convention) |
| `Super+T` float toggle | `cmd+shift+space` | Different key |
| Hyprland dwindle auto-tiling | AeroSpace manual | AeroSpace is manual by default |
| Notification management | macOS native | Different model |

---

## 12. Phase 2 Considerations

- **Sketchybar:** `home/darwin/sketchybar.nix` — workspace indicators using
  AeroSpace `aerospace-workspace-change` events.
- **`cmd+comma` conflict:** If split-toggle on `cmd+,` proves annoying (Preferences
  in many apps), move it to a resize-mode sub-binding.
- **`home/core/darwin.nix`:** Currently empty stub. macOS shell config accumulates
  here over time.
- **NixOS keyd + Ghostty + Hyprland:** Implement §9 as part of the NixOS Hyprland
  migration, using this plan's Mac config as the baseline.
