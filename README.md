# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Secrets Management](#secrets-management)
- [Task Automation](#task-automation)
- [Acknowledgements](#acknowledgements)
- [Guidance and Resources](#guidance-and-resources)

---

## Feature Highlights

- Flake-based multi-host, multi-platform configurations for NixOS, Darwin, and standalone Home-Manager
  - Modular architecture using [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/vic/import-tree) for automatic module discovery
  - Host specifications defined declaratively in `hostSpecs/` with a formal schema
  - Multi-context modules that can register NixOS, Darwin, and Home-Manager configs from a single file
- Secrets management via sops-nix and a private `nix-secrets` repo included as a flake input
- Declarative, btrfs-on-LUKS disk partitioning via disko
- Automated remote-bootstrapping of NixOS via scripts in `scripts/`
- Custom NixOS recovery/installer ISO
- Theming via stylix
- Task automation via [go-task](https://taskfile.dev/) (`Taskfile.yaml`)

## Requirements

- NixOS 25.11+ / nix-darwin 25.11+ / Home-Manager release-25.11
- For secrets: access to the private `nix-secrets` repo via SSH
- Patience

This is a tweaked version of the repo originally provided by [EmergentMind](https://github.com/EmergentMind/nix-config/). Check out his repos and resources if you want to build your own.

## Structure Quick Reference

```
.
├── flake.nix              # Entrypoint — uses flake-parts + import-tree to auto-discover modules
├── Taskfile.yaml          # Task runner for build, rebuild, lint, format, etc.
├── hostSpecs/             # Declarative host specifications (hostname, platform, features)
│   ├── host-spec.nix      # Schema definition for host specs
│   ├── luna.nix
│   ├── terra.nix
│   ├── work.nix
│   ├── penguin.nix
│   ├── toshibachromebook.nix
│   └── iso.nix
├── modules/               # All configuration modules, auto-imported by import-tree
│   ├── flake/             # Flake infrastructure (host-specs, module namespaces, dev shell, git hooks)
│   ├── profiles/          # Composable profiles (base, darwin-base, workstation)
│   │   ├── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv)
│   │   └── _ssh-keys/    # Public SSH keys
│   ├── system/            # System-level modules (sops, ssh, docker, homebrew, smbclient)
│   ├── hardware/          # Hardware-specific modules (nvidia, yubikey, keyboards, rgb)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── scripts/               # Bootstrap and utility scripts
├── nixos-installer/       # Stripped-down flake for initial NixOS installation
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host | Platform | Config Type | Description |
|------|----------|-------------|-------------|
| **luna** | x86_64-linux | `nixosConfigurations` | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060 |
| **terra** | x86_64-linux | `nixosConfigurations` | AMD desktop — workstation + GNOME + gaming + NVIDIA RTX 5080 + streaming |
| **work** | aarch64-darwin | `darwinConfigurations` | macOS work machine — Homebrew, Hammerspoon, work-specific git config |
| **penguin** | x86_64-linux | `homeConfigurations` | Standalone home-manager (WSL / non-NixOS Linux) |
| **toshibachromebook** | x86_64-linux | `nixosConfigurations` | Minimal ChromeBook config |
| **iso** | x86_64-linux | `nixosConfigurations` | Custom NixOS installer/recovery ISO |

## Module System

Modules use a dendritic registration pattern powered by flake-parts. Each module registers itself under one or more namespaces:

```nix
# Example: a module registering both NixOS and home-manager configs
flake.modules.nixos.gnome = { ... };
flake.modules.homeManager.gnome = { ... };
```

Available namespaces: `flake.modules.nixos`, `flake.modules.darwin`, `flake.modules.homeManager`, `flake.modules.generic`.

Hosts compose their configuration by importing modules:

```nix
# In modules/hosts/terra.nix
modules = with inputs.self.modules.nixos; [
  workstation gnome docker gaming nvidia-rtx5080 ...
];
```

Home-manager modules are wired in via `home-manager.sharedModules` at the profile level, so they automatically apply to all users on a host.

## Secrets Management

Secrets are stored in a private `nix-secrets` repository pulled in as a flake input and managed with [sops-nix](https://github.com/Mic92/sops-nix).

- Secrets are YAML files in the `nix-secrets` repo (`sops/shared.yaml`, `sops/<hostname>.yaml`)
- Age encryption keys are bootstrapped from host SSH keys (`/etc/ssh/ssh_host_ed25519_key`)
- Home-manager secrets use `~/.config/sops/age/keys.txt`
- Configured in `modules/system/sops.nix` with both NixOS and home-manager integration

## Task Automation

Common operations are automated via `Taskfile.yaml`:

| Command | Description |
|---------|-------------|
| `task rebuild` | Rebuild current NixOS host |
| `task rebuild:<host>` | Rebuild a specific NixOS host |
| `task build_darwin:<host>` | Rebuild a nix-darwin host |
| `task build_home:<target>` | Rebuild standalone home-manager |
| `task build` | Build a host without switching (default: luna) |
| `task build-all` | Build all NixOS host configurations |
| `task update` | Update flake inputs |
| `task lint` | Run statix and deadnix |
| `task fmt` | Format all Nix files with nixfmt |
| `task check` | Full pre-push check (format + lint + flake check) |
| `task iso` | Build the installer/recovery ISO |
| `task garbage_collect` | Remove store objects older than 7 days |

## Guidance and Resources

- [NixOS.org Manuals](https://nixos.org/learn/)
- [Official Nix Documentation](https://nix.dev)
  - [Best practices](https://nix.dev/guides/best-practices)
- [Noogle](https://noogle.dev/) - Nix API reference documentation.
- [Official NixOS Wiki](https://wiki.nixos.org/)
- [NixOS Package Search](https://search.nixos.org/packages)
- [NixOS Options Search](https://search.nixos.org/options?)
- [Home Manager Option Search](https://home-manager-options.extranix.com/)
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) - an excellent introductory book by Ryan Yin
