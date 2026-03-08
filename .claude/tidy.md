# Architectural Tidy-Up Opportunities

> Reviewed 2026-03-03. Reference: `.claude/research.md`

Items here don't break anything. They're about reducing friction for future changes — inconsistencies that force you to remember "this one's different," duplicated patterns that could diverge silently, and code in surprising locations.

---

## 1. Ghostty is configured two completely different ways

**Linux** (`home/optional/gnome/ghostty.nix`): Uses the `programs.ghostty` home-manager module with structured `settings` attrset, zsh integration, and `TERM` session variable.

**macOS** (`home/ian.preston/work.nix`): Writes a raw text file to `~/Library/Application Support/com.mitchellh.ghostty/config` via `home.file`.

This means the two configs can't share settings, and the macOS one won't pick up any future home-manager module improvements (setting validation, shell integration, etc.). The settings themselves also differ silently — Linux uses `font-family = "monospace"` (Stylix-managed) while macOS hardcodes `FiraCode Nerd Font Mono`; font size is 11 on both but that's coincidental, not shared.

**Opportunity**: Use `programs.ghostty` on macOS too, with platform-conditional overrides for macOS-specific keys like `macos-titlebar-style`.

---

## 2. Sudo configuration contradicts itself

`hosts/common/core/nixos.nix` sets:
```
Defaults timestamp_timeout=120  # only ask for password every 2h
Defaults pwfeedback              # password visible as asterisks
```

`hosts/common/users/primary/nixos.nix` sets:
```nix
security.sudo.wheelNeedsPassword = false;
```

The timeout and feedback settings are dead code — wheel users never see a password prompt. If the intent is passwordless sudo, the `extraConfig` lines are misleading. If the intent is eventual password-based sudo (e.g., after enabling impermanence), the `wheelNeedsPassword` setting needs to go.

**Opportunity**: Decide on one approach and remove the other.

---

## 3. Host disk configs duplicate the reusable template

`hosts/common/disks/terra.nix` and `luna.nix` are hand-written btrfs layouts. `hosts/common/disks/btrfs-disk.nix` is a parameterized template that produces the same partition structure (ESP + btrfs with `@root`, `@nix`, optional `@swap`).

Terra and luna could be expressed as:
```nix
# terra.nix
import ./btrfs-disk.nix { disk = "/dev/nvme0n1"; withSwap = true; swapSize = "32"; }
```

Luna would need the template extended for its secondary SSD, but the primary disk portion is identical.

Having both hand-written and templated versions means fixes to the partition layout (mount options, subvolume names) need to be applied in multiple places.

**Opportunity**: Migrate terra to use `btrfs-disk.nix`. Extend the template with an optional secondary disk parameter for luna.

---

## 4. `scanPaths` vs explicit imports is inconsistent

| Directory | Import method |
|-----------|--------------|
| `hostSpecs/default.nix` | `scanPaths` |
| `home/darwin/default.nix` | `scanPaths` |
| `home/core/default.nix` | Explicit import list |
| Host entry points (terra, luna, etc.) | Explicit import list |

There's no clear rule for when to use which. `home/core/` uses explicit imports despite having the same structure as `home/darwin/` (a `default.nix` alongside sibling `.nix` files). The per-host home configs (`home/ipreston/terra.nix`, etc.) also use explicit imports into `home/optional/`.

This isn't necessarily wrong — explicit imports give finer control — but the lack of a consistent convention means you have to check each directory to know how it works.

**Opportunity**: Pick a convention and document it. A reasonable one: `scanPaths` for directories where every file should always be loaded (core modules, hostSpecs); explicit imports where files are selectively composed (optional modules, per-host configs). Then audit to ensure the current usage matches.

---

## 5. Empty platform stubs serve no purpose

Three files are empty stubs:
- `hosts/common/core/darwin.nix` → `{ }`
- `hosts/common/users/primary/darwin.nix` → `{ }`
- `home/core/darwin.nix` → `{ ... }: { }`

These exist for symmetry with their `nixos.nix` counterparts, but they create a maintenance illusion — it looks like darwin has platform-specific config at these levels when it doesn't. If someone adds darwin-specific logic, they might put it here or in `hosts/darwin/work/` or in `home/darwin/`, with no guidance on which is correct.

**Opportunity**: Either add a comment to each explaining the intended scope (e.g., "darwin-specific core user config goes here — e.g., launchd services, macOS shell setup"), or remove them and handle the conditional import in the parent `default.nix` with `lib.optional (!hostSpec.isDarwin)`.

---

## 6. ISO duplicates nix settings that `core/nixos.nix` already provides

`hosts/nixos/iso/default.nix` sets:
```nix
nix = {
  settings.experimental-features = [ "nix-command" "flakes" ];
  extraOptions = "experimental-features = nix-command flakes";
};
```

`hosts/common/core/nixos.nix` already sets `experimental-features` in `nix.settings`. The ISO additionally sets the same thing via `extraOptions` (a legacy mechanism). But the ISO doesn't import `hosts/common/core` at all — it bypasses the standard host structure, pulling in only `hosts/common/users/primary/` and `hosts/common/optional/minimal-user.nix`.

This means the ISO misses out on all core host config: locale, timezone, nix registries, trusted-users, optimise settings, SSH config, and sops. Some of that is intentional (no sops on a live ISO), but locale and nix settings probably aren't.

**Opportunity**: Factor the universally-desired nix settings and locale config out of `core/nixos.nix` into a smaller base module that the ISO can also import, rather than duplicating a subset.

---

## 7. Debug trace left in `home/core/default.nix`

```nix
homeDirectory = builtins.trace "DEBUG ${hostSpec.home}" lib.mkDefault hostSpec.home;
```

This prints to stderr on every evaluation. It's noise during builds and could mask real warnings.

**Opportunity**: Remove it.

---

## 8. Duplicate package in `home/core/packages.nix`

`ripgrep` appears twice in the package list. Nix deduplicates it, so it's harmless, but it suggests the list was edited without checking for existing entries.

**Opportunity**: Remove the duplicate.

---

## 9. Per-host home configs all redundantly import `../core/default.nix`

Every file in `home/ipreston/` and `home/ian.preston/` starts with:
```nix
imports = [ ../core/default.nix ... ];
```

But `hosts/common/users/primary/default.nix` is what actually wires up home-manager, importing the per-host home file via:
```nix
import (customLib.relativeToRoot "home/${hostSpec.username}/${hostSpec.hostNameFile}.nix")
```

The core import could be done once at that level instead of repeated in every per-host file. This would mean per-host home files only list their optional modules, which is what they're actually differentiating.

**Opportunity**: Move the `../core/default.nix` import into `users/primary/default.nix` where home-manager is configured, and remove it from each per-host file. This also eliminates the risk of a per-host file forgetting to include core.

---

## 10. Work home config imports `../darwin` but other hosts don't import platform modules

`home/ian.preston/work.nix` imports both `../core/default.nix` and `../darwin`. This is how AeroSpace gets pulled in. But the core `default.nix` already conditionally imports `./darwin.nix` or `./nixos.nix` based on `isDarwin`.

The `home/darwin/` directory (with AeroSpace) is a separate concept from `home/core/darwin.nix` (platform-specific core config). But the naming makes this confusing:
- `home/core/darwin.nix` — empty platform stub imported by `home/core/default.nix`
- `home/darwin/` — optional macOS home modules imported explicitly by work.nix

Someone adding a new darwin home module has to know the difference between these two locations.

**Opportunity**: Either merge `home/darwin/` into the `home/core/darwin.nix` platform stub (if AeroSpace should always be loaded on macOS), or rename `home/darwin/` to something like `home/optional/darwin/` to make it clear it's an optional module set parallel to `home/optional/gnome/`.

---

## 11. Ghostty font name inconsistency with Stylix

`hosts/common/optional/themes.nix` defines the monospace font as:
```nix
name = "Firacode Nerd Font Mono";
```

`home/optional/gnome/ghostty.nix` uses:
```nix
font-family = "monospace";
```

`home/ian.preston/work.nix` uses:
```nix
font-family = FiraCode Nerd Font Mono
```

The Linux Ghostty relies on fontconfig's `monospace` alias (which Stylix configures), while the macOS one hardcodes the font name. If the Stylix font ever changes, macOS won't follow.

**Opportunity**: This is related to item 1 — using the `programs.ghostty` module on both platforms would let Stylix manage the font consistently.

---

## 12. `hostSpec` vs `config.hostSpec` — two access patterns

In `flake.nix`, host specs are evaluated once and passed as `hostSpec` (singular) via `specialArgs`. Modules access them as the `hostSpec` function argument.

But the impermanence disk templates (`btrfs-impermanence-disk.nix`, `btrfs-luks-impermanence-disk.nix`) reference `config.hostSpec.persistFolder` — an option that doesn't exist in the current `host-spec.nix` option definition. This would fail at evaluation time if those templates were actually used.

**Opportunity**: Before using the impermanence templates, add `persistFolder` to the hostSpec options. Also decide whether disk configs should access host metadata through `config.hostSpec` (module option) or through `specialArgs` — mixing the two patterns will be confusing.

---

## 13. No `home/optional/` modules are auto-discovered

Unlike `hostSpecs/` or `home/darwin/`, the `home/optional/` directory has no `default.nix` and isn't scanned. Every per-host config must explicitly list each optional module path (`../optional/browser.nix`, `../optional/media.nix`, etc.).

This is fine for selective composition, but it means typos in paths are only caught at evaluation time, and there's no single place to see which optional modules exist.

**Opportunity**: This is intentional by design (optional = explicitly selected), but a `home/optional/default.nix` that just documents available modules as comments would help discoverability without changing behavior.

---

## Summary by effort

| Effort | Items |
|--------|-------|
| Trivial (minutes) | 7 (debug trace), 8 (duplicate ripgrep) |
| Small (< 1 hour) | 2 (sudo), 5 (empty stubs), 11 (font names) |
| Medium (1-3 hours) | 1 (ghostty unification), 3 (disk templates), 9 (core import), 10 (darwin module naming) |
| Larger (half day+) | 4 (scanPaths convention), 6 (ISO base module), 12 (hostSpec access pattern), 13 (optional module discovery) |
