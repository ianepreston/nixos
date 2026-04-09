# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Secrets Management](#secrets-management)
- [Task Automation](#task-automation)
- [Bootstrapping a New Host](#bootstrapping-a-new-host)
- [Guidance and Resources](#guidance-and-resources)

---

## Feature Highlights

- Flake-based multi-host, multi-platform configurations for NixOS, Darwin, and standalone Home-Manager
  - Modular architecture using [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/vic/import-tree) for automatic module discovery
  - Host specifications defined declaratively in `hostSpecs/` with a formal schema
  - Multi-context modules that can register NixOS, Darwin, and Home-Manager configs from a single file
- Secrets management via sops-nix and a private `nix-secrets` repo included as a flake input
- Declarative, btrfs-on-LUKS disk partitioning via disko
- Automated remote-bootstrapping of NixOS via [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and Taskfile tasks
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
├── scripts/               # Utility scripts (dconf, sops check)
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
| `task bootstrap:new HOST=x DEST=ip` | Full bootstrap pipeline (install + hwconfig + hostkey + sync + rebuild) |
| `task bootstrap:install HOST=x DEST=ip` | Run nixos-anywhere to install NixOS on target |
| `task bootstrap:hwconfig HOST=x DEST=ip` | Extract hardware-configuration.nix from target |
| `task bootstrap:hostkey HOST=x DEST=ip` | Derive age key from target SSH key, print SOPS instructions |
| `task bootstrap:sync HOST=x DEST=ip` | Rsync nixos and nix-secrets to target |
| `task bootstrap:rebuild HOST=x DEST=ip` | Run nixos-rebuild switch on target |

## Bootstrapping a New Host

### Prerequisites

- Target machine booted into a NixOS ISO (use `task iso` for a custom one)
- This repo and `nix-secrets` cloned on the source machine (e.g. `~/src/{nixos,nix-secrets}`)
- A key on the source machine that can decrypt secrets (`~/.config/sops/age/keys.txt`)

### 1. Create host config files

Before bootstrapping, the target host needs configuration in this repo:

- `hostSpecs/newhostname.nix` — host specification (copy from an existing host)
- `modules/hosts/_newhostname-disks.nix` — disko disk layout
- `modules/hosts/newhostname.nix` — host module (which modules to compose)

If you don't have a hardware config yet, boot the ISO on the target and run:

```bash
ssh root@TARGET "nixos-generate-config --no-filesystems --show-hardware-config" \
  > modules/hosts/_newhostname-hardware.nix
```

Or use `task bootstrap:hwconfig` after installation to extract it.

### 2. Run the bootstrap

```bash
# Full pipeline — installs, extracts hardware config, shows SOPS instructions, syncs, rebuilds:
task bootstrap:new HOST=newhostname DEST=192.168.1.50

# With LUKS encryption:
task bootstrap:new HOST=newhostname DEST=192.168.1.50 LUKS_PASS=temp-passphrase
```

Individual steps can be run independently for partial re-runs after failures:

```bash
task bootstrap:install  HOST=newhostname DEST=192.168.1.50  # nixos-anywhere only
task bootstrap:hwconfig HOST=newhostname DEST=192.168.1.50  # extract hardware config
task bootstrap:hostkey  HOST=newhostname DEST=192.168.1.50  # derive age key, print instructions
task bootstrap:sync     HOST=newhostname DEST=192.168.1.50  # rsync configs to target
task bootstrap:rebuild  HOST=newhostname DEST=192.168.1.50  # remote nixos-rebuild switch
```

### 3. Post-install: add secrets

After `bootstrap:hostkey` prints the age public key, update `nix-secrets/.sops.yaml`:

1. Add the host key under `keys.hosts` with an anchor
2. Add the host to `shared.yaml`'s creation rule
3. Create a creation rule for `newhostname.yaml`
4. Run `sops updatekeys sops/*.yaml`, commit, and push nix-secrets
5. Run `nix flake update nix-secrets` in this repo
6. Re-run `task bootstrap:sync` and `task bootstrap:rebuild`

### Reinstalling an existing host

For hosts that already have keys and configs, only the install and sync/rebuild steps are needed:

```bash
task bootstrap:install HOST=existinghost DEST=192.168.1.50
# Wait for reboot, then:
task bootstrap:sync    HOST=existinghost DEST=192.168.1.50
task bootstrap:rebuild HOST=existinghost DEST=192.168.1.50
```

### VM testing

Use quickemu on terra to test the bootstrap against VMs before touching real hardware.
Build a custom ISO with `task iso`, then create a VM pointing at `latest.iso` and run
the bootstrap tasks against the VM's IP.

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
