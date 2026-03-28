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

**Severity**: Low — workflows_update.md asks about this but doesn't depend on
it.

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

## Issue 5: Symbolic hotkey parameters need careful validation

**Severity**: Medium — wrong values silently fail.

**Problem**: The `com.apple.symbolichotkeys` plist uses
`[ASCII, keycode, modifier_mask]` tuples. Getting any of these wrong results in
the shortcut silently not working. The keycodes for number keys specifically:

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
`alt+tab` for window-level switching (Hammerspoon). This matches the GNOME model
where `alt+tab` switches windows and `super+tab` could switch apps. Test that
they don't interfere with each other.

---

## Issue 9: Browser/tab shortcuts use different physical keys per platform

**Severity**: Resolved.

**Problem**: Browser and Ghostty tab shortcuts used each platform's native
binding: `cmd+t`/`cmd+w` on macOS (D+t/D+w on Voyager) and `ctrl+t`/`ctrl+w` on
GNOME (A+t/A+w on Voyager). Different physical keys for the same action.

**Resolution**: Use mac-native cmd+t/w/n (D+t/w/n on Voyager) and remap GNOME
with keyd: super+{t,w,n} → ctrl+{t,w,n}. This makes D+t/w/n the universal
physical key on both platforms. macOS is completely native, GNOME uses keyd to
translate super → ctrl for these combos. ctrl+t/w/n still works natively on
GNOME too (A+t/w/n on Voyager).

---

## Issue 10: Ghostty macOS config uses raw file write, not programs.ghostty

**Severity**: Low — technical debt, not blocking.

**Problem**: The macOS Ghostty config in `home/ian.preston/work.nix` uses
`home.file."Library/Application Support/com.mitchellh.ghostty/config"` (raw file
write) while GNOME uses `programs.ghostty` (home-manager module). The
`workflows.md` notes this was due to past issues. Adding keybindings to the
macOS config means appending to the raw text string rather than using the
structured `settings.keybind` list.

**Proposed solution**: Add keybind lines directly to the raw text config for
now. This works fine — Ghostty's config format is just `key = value` lines.
Migrating to `programs.ghostty` on macOS can be a separate future cleanup task
if desired.

---

## Issue 12: Mission Control keyboard window selection doesn't work

**Severity**: Low — mouse selection still works, this is a convenience feature.

**Test**: 1.8 — arrow keys do nothing when Mission Control is open.

**Problem**: When Mission Control is activated (via hot corner, ctrl+up, or F3),
arrow keys don't select between visible windows. macOS Mission Control has
limited keyboard navigation — it's primarily a mouse/trackpad-driven interface.
Arrow keys move between Spaces (the top row) but don't navigate individual
windows within the current Space view.

**Proposed solutions**:

1. **Accept limitation** — Mission Control is inherently mouse-driven on macOS.
   Use it for visual overview, then click the desired window. Arrow keys aren't
   the intended interaction model.
2. **Use alt+tab instead** — Hammerspoon's alt+tab window switcher (test 2.16)
   already provides keyboard-driven window selection within the current Space.
   This is the better keyboard workflow for switching windows.
3. **Explore Hammerspoon window chooser** — Hammerspoon has a
   `hs.window.switcher` or `hs.chooser` API that could present a searchable
   window list on a hotkey, but this adds complexity for marginal benefit over
   alt+tab.

**Recommendation**: Accept (option 1). Alt+tab covers the keyboard use case.

---

## Issue 13: ctrl+N Space switching not working on macOS

**Severity**: Medium — blocks direct Space-by-number navigation (tests
2.5–2.10).

**Test**: 2.5–2.9 fail (ping sound, no action), 2.10 fails (Voyager dependent).

**Problem**: `ctrl+1` through `ctrl+5` don't switch to the corresponding Space.
A system ping sound plays, indicating macOS recognizes the keypress but can't
execute the action. Two possible causes:

1. **Symbolic hotkey config not applied correctly** — The
   `com.apple.symbolichotkeys` plist values may have wrong keycodes or modifier
   masks, or the settings weren't activated (requires logout/login or
   `killall Dock`). Issue 5 warned about this.
2. **Conflict with application shortcuts** — The test notes mention "ctrl+number
   is used by Slack." If Slack (or another app) claims ctrl+N globally or in the
   foreground app, macOS may not pass it to the Space switcher.

**Proposed solutions**:

1. **Debug the symbolic hotkey config** — Run
   `defaults read com.apple.symbolichotkeys` and verify entries 118–122 (Space
   1–5 shortcuts) have the correct format:
   `{enabled = 1; value = {parameters = (49, 18, 262144); type = standard;};}`
   where 262144 = ctrl modifier. Try logout/login if values look correct.
2. **Remap to a different modifier** — If ctrl+N conflicts are widespread, use
   `hyper+N` (F+number on Voyager) instead. This avoids all application
   conflicts since hyper (ctrl+alt+shift+cmd) is never used by apps. Would need
   equivalent GNOME binding update for parity.
3. **Use Hammerspoon for Space switching** — Hammerspoon can switch Spaces via
   `hs.spaces.gotoSpace(N)`. Bind to hyper+N or any other combo. More reliable
   than symbolic hotkeys and easier to debug.

**Recommendation**: Start with option 1 (debug). If the config is correct but
conflicts persist, move to option 2 (hyper+N) for both platforms.

---

## Summary

| Issue                                      | Severity   | Blocks implementation? | Action                              |
| ------------------------------------------ | ---------- | ---------------------- | ----------------------------------- |
| 1. Spaces can't be auto-created            | Medium     | No — manual step       | Document prerequisite               |
| 2. App-to-Space assignment fragile         | Low        | No                     | Don't implement                     |
| 3. ctrl+arrows conflicts with word nav     | Low-Medium | No                     | Accept tradeoff                     |
| 4. Launcher parity imperfect               | Low        | No                     | Accept difference                   |
| 5. Symbolic hotkey params tricky           | Medium     | No — test carefully    | Validate per-key                    |
| 6. Copy/paste not universal on GNOME       | Low        | No                     | Future enhancement (xremap)         |
| 7. Homebrew won't auto-uninstall           | Low        | No                     | Manual step                         |
| 8. Two tab switchers on macOS              | Low        | No                     | Keep both                           |
| 9. Browser/tab key asymmetry               | Resolved   | No                     | Native Mac + keyd on GNOME          |
| 10. Ghostty config inconsistency           | Low        | No                     | Append to raw config                |
| 11. workflows_update browser assumes remap | Resolved   | No                     | Native Mac + keyd on GNOME          |
| 12. Mission Control keyboard nav           | Low        | No                     | Accept — use alt+tab instead        |
| 13. ctrl+N Space switching broken          | Medium     | Partially              | Debug config, else remap to hyper+N |
