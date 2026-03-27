# Issues & Challenges: Unified Workflow (v2)

Issues identified during research of the `workflows_update.md` proposals against
actual macOS, nix-darwin, GNOME, and home-manager capabilities.

---

## Issue 1: macOS Spaces cannot be created programmatically

**Severity**: Medium — affects the "auto-populate multiple virtual desktops"
request in workflows_update.md.

**Problem**: There is no API, `defaults write` command, or nix-darwin option to
programmatically create macOS Spaces. Apple provides no scriptable interface for
this. Spaces can only be created manually through Mission Control.

**Impact**: The workflows_update.md asks "Two nice things here would be to have
my Nix config auto populate multiple virtual desktops." This is not possible on
macOS. Additionally, `ctrl+N` Space-switching shortcuts only work if the
corresponding Spaces already exist.

**Proposed solution**: Document this as a one-time manual setup step. After
`darwin-rebuild switch`, manually create 5 Spaces via Mission Control. The
symbolic hotkey config will then enable `ctrl+1` through `ctrl+5`. Add a comment
in the nix config explaining this prerequisite.

---

## Issue 2: macOS app-to-Space assignment is fragile

**Severity**: Low — workflows_update.md asks about this but doesn't depend on it.

**Problem**: Assigning apps to specific Spaces requires the Space's UUID, which
is ephemeral and changes when Spaces are recreated. The UUIDs in
`com.apple.spaces` are not stable across rebuilds, display changes, or even
reboots in some cases.

**Proposed solution**: Don't implement this. It's not reliable enough for
declarative config. If needed later, a Hammerspoon script could assign apps on
launch, but this adds complexity for questionable benefit given the stated
workflow of focusing on one app at a time.

---

## Issue 3: `ctrl+left/right` for Spaces conflicts with text editing

**Severity**: Low-Medium — depends on usage patterns.

**Problem**: `ctrl+left/right` is the standard macOS shortcut for word-by-word
cursor movement in text fields. Using it for Space switching means losing that
shortcut system-wide on macOS. On the Voyager with home-row mods, this is
`hold-A + arrow`, which may also be used for word navigation.

**Proposed solution**: This is the macOS default for Mission Control left/right,
so it's a well-understood tradeoff that most macOS users live with. Word
navigation can still be done with `opt+left/right` (which moves by word on
macOS). On the Voyager, that's `hold-S + arrow`. If this proves annoying in
practice, document it in the testing plan as a potential revert. GNOME doesn't
have this conflict since `ctrl+left/right` in terminals/editors is typically
handled by the application, not the DE.

---

## Issue 4: App launcher parity is imperfect

**Severity**: Low — the workflows_update.md acknowledges this is fine.

**Problem**: macOS uses `cmd+space` for Spotlight, and the proposal is to use
`super+space` for GNOME Activities. On the Voyager, `cmd` is the D key (ring
finger hold) and `super` maps to the same key on Linux. So the physical keys
are the same — `hold-D + space`. However, Spotlight and GNOME Activities are
functionally different (Spotlight is a search bar, Activities is an overview +
search). Bare `Super` currently opens Activities on GNOME — disabling this to
require `Super+space` means a bare Super tap does nothing.

**Proposed solution**: Implement as planned (`Super+space` for GNOME). The
functional difference between Spotlight and Activities is acceptable. If the
user misses bare-Super activation, it can be re-enabled by removing the
`overlay-key = ""` setting. Note this in testing.

---

## Issue 5: Symbolic hotkey parameters need careful validation

**Severity**: Medium — wrong values silently fail.

**Problem**: The `com.apple.symbolichotkeys` plist uses `[ASCII, keycode,
modifier_mask]` tuples. Getting any of these wrong results in the shortcut
silently not working. The keycodes for number keys specifically:

- `1` = keycode 18, `2` = 19, `3` = 20, `4` = 21, `5` = 23 (note: NOT 22!)
- `6` = 22, `7` = 26, `8` = 28, `9` = 25, `0` = 29

The keycode sequence is non-sequential and easy to get wrong. Additionally, the
symbolic hotkey IDs for Mission Control left/right (`79`, `81`) need the special
ASCII value `65535` (not a printable character).

**Proposed solution**: Implement with the researched values, but the testing
plan includes per-key verification. If a specific key doesn't work, we can debug
by reading back the plist with `defaults read com.apple.symbolichotkeys` and
comparing against the expected values. Start with just 3-5 Spaces to keep the
surface area manageable.

---

## Issue 6: Copy/paste parity is Ghostty/browser-only on GNOME

**Severity**: Low — workflows_update.md mentions "configure GNOME to use them
universally" for cmd+c/v.

**Problem**: On GNOME, `super+c`/`super+v` for copy/paste only works in apps
that are explicitly configured for it (Ghostty). There's no dconf setting for
system-wide super→ctrl remapping. Making this truly universal would require
a key remapping daemon like `xremap` or `keyd`, adding another system-level
component.

**Impact**: The physical keys `D+c`/`D+v` will work in Ghostty (super+c/v
binding) and in browsers (ctrl+c/v is native, but that's `A+c` on Voyager, not
`D+c`). This means copy/paste physical keys differ between platforms in non-
terminal, non-Ghostty apps.

**Proposed solution**: Accept this as a known limitation for now. The most
common apps (Ghostty, browser) are covered. If this becomes a pain point, adding
`xremap` is straightforward — it has a NixOS home-manager module. Flag it as a
future enhancement rather than blocking the initial implementation on it. Note:
the browser actually uses `ctrl+c`/`ctrl+v` natively on both platforms, so the
physical key is `A+c`/`A+v` (hold index finger) — which is consistent. The
mismatch is only in non-browser GUI apps on GNOME.

---

## Issue 7: `homebrew.onActivation.cleanup = "none"` means manual uninstall

**Severity**: Low — one-time manual step.

**Problem**: The current homebrew config has `cleanup = "none"`, meaning
removing `aerospace` from the casks list won't actually uninstall it. The cask
will remain installed until manually removed.

**Proposed solution**: After `darwin-rebuild switch`, manually run
`brew uninstall --cask aerospace`. Consider whether to change cleanup to
`"uninstall"` or `"zap"` going forward, but that's a separate decision with
broader implications (it would affect all casks, not just aerospace).

---

## Issue 8: Hammerspoon alt+tab vs macOS cmd+tab coexistence

**Severity**: Low — but worth noting.

**Problem**: macOS has built-in `cmd+tab` for app switching (groups windows by
app). The plan adds Hammerspoon `alt+tab` for individual window cycling. These
can coexist, but having two different switchers might be confusing. The
workflows_update.md says "cmd+tab to do full app cycling in MacOS is fine to
keep as is."

**Proposed solution**: Keep both. `cmd+tab` for app-level switching (native),
`alt+tab` for window-level switching (Hammerspoon). This matches the GNOME
model where `alt+tab` switches windows and `super+tab` could switch apps. Test
that they don't interfere with each other.

---

## Issue 9: Browser/tab shortcuts use different physical keys per platform

**Severity**: Resolved.

**Problem**: Browser and Ghostty tab shortcuts used each platform's native
binding: `cmd+t`/`cmd+w` on macOS (D+t/D+w on Voyager) and `ctrl+t`/`ctrl+w`
on GNOME (A+t/A+w on Voyager). Different physical keys for the same action.

**Resolution**: Hammerspoon on macOS remaps ctrl+{t,w,n} → cmd+{t,w,n}, so
A+t/w/n (ctrl on Voyager) opens/closes tabs and windows on both platforms.
The native cmd+t/w/n shortcuts still work on macOS too. This is a one-platform
remap (macOS only), keeping Linux completely native.

---

## Issue 10: Ghostty macOS config uses raw file write, not programs.ghostty

**Severity**: Low — technical debt, not blocking.

**Problem**: The macOS Ghostty config in `home/ian.preston/work.nix` uses
`home.file."Library/Application Support/com.mitchellh.ghostty/config"` (raw
file write) while GNOME uses `programs.ghostty` (home-manager module). The
`workflows.md` notes this was due to past issues. Adding keybindings to the
macOS config means appending to the raw text string rather than using the
structured `settings.keybind` list.

**Proposed solution**: Add keybind lines directly to the raw text config for
now. This works fine — Ghostty's config format is just `key = value` lines.
Migrating to `programs.ghostty` on macOS can be a separate future cleanup task
if desired.

---

---

## Issue 11: workflows_update.md browser section assumes cross-platform remap

**Severity**: Resolved.

**Problem**: The `workflows_update.md` Browser section asked about remapping
GNOME browsers to use `cmd+t` (super+t) to match macOS.

**Resolution**: Instead of remapping Linux, Hammerspoon on macOS remaps
ctrl+{t,w,n} → cmd+{t,w,n}. This makes ctrl+t/w/n (A+key on Voyager) the
universal shortcut on both platforms. Linux stays completely native. Only one
platform is remapped (macOS), and the native cmd+t/w/n shortcuts still work
there too.

---

## Summary

| Issue | Severity | Blocks implementation? | Action |
|-------|----------|----------------------|--------|
| 1. Spaces can't be auto-created | Medium | No — manual step | Document prerequisite |
| 2. App-to-Space assignment fragile | Low | No | Don't implement |
| 3. ctrl+arrows conflicts with word nav | Low-Medium | No | Accept tradeoff |
| 4. Launcher parity imperfect | Low | No | Accept difference |
| 5. Symbolic hotkey params tricky | Medium | No — test carefully | Validate per-key |
| 6. Copy/paste not universal on GNOME | Low | No | Future enhancement (xremap) |
| 7. Homebrew won't auto-uninstall | Low | No | Manual step |
| 8. Two tab switchers on macOS | Low | No | Keep both |
| 9. Browser/tab key asymmetry | Low | No | Intentional — platform natives |
| 10. Ghostty config inconsistency | Low | No | Append to raw config |
| 11. workflows_update browser assumes remap | Info | No | Resolved by design principle |
